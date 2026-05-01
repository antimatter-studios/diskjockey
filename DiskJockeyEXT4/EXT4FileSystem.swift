/*
 * EXT4FileSystem.swift — FSKit filesystem module for ext4.
 * Pattern matched from KhaosT/FSKitSample (macOS 26 compatible).
 */

import FSKit
import Foundation

/// Single logging surface — fans out to os_log (system) + NDJSON file
/// (tailed by host app UI) via AppLog's configured sinks.
let log = AppLog(source: "ext4", sinks: AppLog.defaultSinks(source: "ext4"))

/// Wraps FSBlockDeviceResource for C callback access.
/// FSBlockDeviceResource.read requires offset+length aligned to blockSize.
/// We align to the block size and copy the requested window out of the read buffer.
///
/// The `log` property is a subject-tagged logger (carrying
/// `fields["bsd"]=<disk>`) injected at construction time. The
/// `@convention(c)` closure in `loadResource` can't capture Swift
/// state, so it dispatches into this class via an `Unmanaged`
/// pointer and we do the actual logging here — where regular Swift
/// capture semantics apply.
final class BlockDeviceContext {
    let resource: FSBlockDeviceResource
    let blockSize: Int
    let log: TaggedLogger
    /// Records bytes/ops/latency for every callback the FS driver makes
    /// to the underlying block device. Distinct from the file-level
    /// stats kept by EXT4Volume — these are *physical* I/O numbers,
    /// inflated by metadata reads, journal writes, and block alignment.
    let stats: IOStatsCollector

    init(resource: FSBlockDeviceResource, log: TaggedLogger, stats: IOStatsCollector) {
        self.resource = resource
        self.blockSize = Int(resource.blockSize)
        self.log = log
        self.stats = stats
    }

    func read(into buf: UnsafeMutableRawPointer, offset: off_t, length: Int) -> Int32 {
        let bs = max(blockSize, 512)
        let alignedOffset = (Int(offset) / bs) * bs
        let offsetDelta = Int(offset) - alignedOffset
        let alignedLength = ((offsetDelta + length + bs - 1) / bs) * bs

        let tmp = UnsafeMutableRawPointer.allocate(byteCount: alignedLength, alignment: bs)
        defer { tmp.deallocate() }

        let t0 = monotonicNanos()
        do {
            let rawBuf = UnsafeMutableRawBufferPointer(start: tmp, count: alignedLength)
            let bytesRead = try resource.read(into: rawBuf, startingAt: off_t(alignedOffset), length: alignedLength)
            if bytesRead < offsetDelta + length {
                log.error("bdev read short: off=\(offset) len=\(length) alignedOff=\(alignedOffset) alignedLen=\(alignedLength) got=\(bytesRead)", scope: AppLogScope.io)
                stats.recordBdevRead(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
                return EIO
            }
            memcpy(buf, tmp.advanced(by: offsetDelta), length)
            stats.recordBdevRead(bytes: alignedLength, latencyNs: monotonicNanos() &- t0, error: false)
            return 0
        } catch {
            log.error("bdev read error: off=\(offset) len=\(length) err=\(error.localizedDescription)", scope: AppLogScope.io)
            stats.recordBdevRead(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
            return EIO
        }
    }

    /// Mirror image of `read`. FSBlockDeviceResource.write requires the
    /// same block-size alignment as read, so we read-modify-write the
    /// partially-overlapping head and tail blocks when the requested
    /// window doesn't sit on a block boundary.
    func write(from buf: UnsafeRawPointer, offset: off_t, length: Int) -> Int32 {
        // Align to the bigger of logical and physical block size — the
        // kernel buffer cache requires `physicalBlockSize`-aligned
        // operations for sector-addressed devices.
        let logicalBs = Int(resource.blockSize)
        let physicalBs = Int(resource.physicalBlockSize)
        let bs = max(logicalBs, physicalBs, 512)
        let alignedOffset = (Int(offset) / bs) * bs
        let offsetDelta = Int(offset) - alignedOffset
        let alignedLength = ((offsetDelta + length + bs - 1) / bs) * bs

        let tmp = UnsafeMutableRawPointer.allocate(byteCount: alignedLength, alignment: bs)
        defer { tmp.deallocate() }

        // Read the surrounding aligned window when the caller's window
        // doesn't cover it fully (so we don't overwrite untouched bytes).
        // Use plain `read` (verified to work during loadResource), not
        // `metadataRead` (returns EIO during loadResource on at least
        // some devices).
        let t0 = monotonicNanos()
        do {
            let needsHead = offsetDelta != 0
            let needsTail = (offsetDelta + length) != alignedLength
            if needsHead || needsTail {
                let rawBuf = UnsafeMutableRawBufferPointer(start: tmp, count: alignedLength)
                let bytesRead = try resource.read(into: rawBuf,
                                                  startingAt: off_t(alignedOffset),
                                                  length: alignedLength)
                if bytesRead < alignedLength {
                    memset(tmp.advanced(by: bytesRead), 0, alignedLength - bytesRead)
                }
            }
            memcpy(tmp.advanced(by: offsetDelta), buf, length)

            let writeBuf = UnsafeRawBufferPointer(start: tmp, count: alignedLength)
            try resource.delayedMetadataWrite(from: writeBuf,
                                              startingAt: off_t(alignedOffset),
                                              length: alignedLength)
            log.info("bdev write ok: off=\(offset) len=\(length) alignedOff=\(alignedOffset) alignedLen=\(alignedLength)", scope: AppLogScope.io)
            stats.recordBdevWrite(bytes: alignedLength, latencyNs: monotonicNanos() &- t0, error: false)
            return 0
        } catch {
            log.error("bdev delayedMetadataWrite error: off=\(offset) len=\(length) alignedOff=\(alignedOffset) alignedLen=\(alignedLength) bs=\(bs) err=\(error.localizedDescription)", scope: AppLogScope.io)
            stats.recordBdevWrite(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
            return EIO
        }
    }

    /// Flush the kernel buffer cache to disk. Now that we use
    /// `metadataWrite`, calling `metadataFlushWithError:` is meaningful —
    /// it forces any cached metadata blocks (including ones the FS driver
    /// just wrote) out to the device.
    func flush() -> Int32 {
        do {
            try resource.metadataFlush()
            return 0
        } catch {
            log.error("bdev metadataFlush error: \(error.localizedDescription)", scope: AppLogScope.io)
            return EIO
        }
    }
}

@objc(EXT4FileSystem)
final class EXT4FileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    /// FSKit's `startCheck(task:options:)` hands us no resource handle —
    /// only an `FSTask` + `FSTaskOptions` (see FSResource.h ~L442). To
    /// route fsck back to the right mounted volume's backend we register
    /// `(bsdName, EXT4Backend)` keyed by resource identity at
    /// `loadResource` time and look it up here. Cleared on
    /// `unloadResource`.
    ///
    /// Keyed by `ObjectIdentifier(FSResource)` — FSKit hands us the same
    /// FSResource instance for the lifetime of the mount, so the
    /// in-process pointer is a stable, unique handle. We don't need
    /// `FSResource.identifier` (UUID) because we never persist this map.
    /// Guarded by an unfair lock so `startCheck` can read it without
    /// awaiting an actor.
    fileprivate struct MountedResource {
        let bsdName: String
        let backend: EXT4Backend
    }
    fileprivate static let mountedResources = OSAllocatedUnfairLock<[ObjectIdentifier: MountedResource]>(
        initialState: [:])

    override init() {
        super.init()
    }


    func probeResource(
        resource: FSResource,
        replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        log.info("probe called", scope: AppLogScope.probe)
        guard let blockDevice = resource as? FSBlockDeviceResource else {
            log.warn("probe: resource is not a block device — not recognized", scope: AppLogScope.probe)
            replyHandler(.notRecognized, nil)
            return
        }
        // All subsequent log lines in this probe carry `fields["bsd"]`
        // so the host app routes them into the matching partition's
        // per-disk log strip. `scope: probe` puts them in the
        // detection bucket for both system + per-mount denylists.
        let dlog = TaggedLogger(
            log, fields: ["bsd": blockDevice.bsdName], kind: "ext4.probe",
            scope: AppLogScope.probe
        )
        dlog.info("probe \(blockDevice.bsdName): blockSize=\(blockDevice.blockSize) blockCount=\(blockDevice.blockCount)")

        do {
            var buf = [UInt8](repeating: 0, count: 1024)
            let bytesRead = try buf.withUnsafeMutableBytes { rawBuf in
                try blockDevice.read(into: rawBuf, startingAt: 1024, length: 1024)
            }

            guard bytesRead >= 58 else {
                dlog.info("probe: read \(bytesRead) bytes (< 58) — not ext4")
                replyHandler(.notRecognized, nil)
                return
            }

            let magic = UInt16(buf[56]) | (UInt16(buf[57]) << 8)
            guard magic == 0xEF53 else {
                dlog.info("probe: superblock magic mismatch (0x\(String(magic, radix: 16))) — not ext4")
                replyHandler(.notRecognized, nil)
                return
            }

            let nameBytes = buf[120..<136]
            let rawName = String(bytes: nameBytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
            let volumeName = rawName.isEmpty ? "ext4" : rawName
            let uuidBytes = Array(buf[104..<120])
            let containerID = FSContainerIdentifier(uuid: NSUUID(uuidBytes: uuidBytes) as UUID)
            dlog.info("probe: recognized ext4 volume \"\(volumeName)\"")

            replyHandler(.usable(name: volumeName, containerID: containerID), nil)
        } catch {
            dlog.error("probe: block-device read failed — \(error.localizedDescription)")
            replyHandler(.notRecognized, nil)
        }
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        log.info("loadResource called", scope: AppLogScope.lifecycle)
        guard let blockDevice = resource as? FSBlockDeviceResource else {
            log.error("loadResource: resource is not a block device — EINVAL", scope: AppLogScope.lifecycle)
            replyHandler(nil, POSIXError(.EINVAL))
            return
        }
        let bsdName = blockDevice.bsdName
        // From here on every line carries `fields["bsd"]` — goes to the
        // partition detail view's per-disk log strip + central log.
        // Default scope=lifecycle covers the mount/load chatter; the
        // volume.* and io.* events emitted via this logger override
        // scope per-call.
        let dlog = TaggedLogger(
            log, fields: ["bsd": bsdName], kind: "ext4.load",
            scope: AppLogScope.lifecycle
        )
        // Surface every signal FSKit + DA give us so we can diagnose
        // why writes are/aren't allowed: bsd, sizes, isWritable flag from
        // the resource, the physical block size (the metadata cache
        // requires sector-aligned operations to physicalBlockSize, not
        // logical blockSize), and the raw taskOptions array.
        dlog.info("loadResource \(bsdName): blockSize=\(blockDevice.blockSize) physicalBlockSize=\(blockDevice.physicalBlockSize) blockCount=\(blockDevice.blockCount) isWritable=\(blockDevice.isWritable) taskOptions=\(options.taskOptions)")

        // One stats collector per mount. Lifetime is the volume's:
        // started here so block-device callbacks made during mount
        // (superblock read, journal replay) get counted, stopped in
        // EXT4Volume.deactivate.
        let stats = IOStatsCollector(label: bsdName, log: dlog)
        let context = BlockDeviceContext(resource: blockDevice, log: dlog, stats: stats)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        var cfg = fs_ext4_blockdev_cfg_t()
        cfg.read = { ctx, buf, offset, length in
            guard let ctx = ctx, let buf = buf else { return EIO }
            let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
            return context.read(into: buf, offset: off_t(offset), length: Int(length))
        }
        cfg.write = { ctx, buf, offset, length in
            guard let ctx = ctx, let buf = buf else { return EIO }
            let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
            return context.write(from: buf, offset: off_t(offset), length: Int(length))
        }
        cfg.flush = { ctx in
            guard let ctx = ctx else { return EIO }
            let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
            return context.flush()
        }
        cfg.context = contextPtr
        cfg.size_bytes = blockDevice.blockCount * blockDevice.blockSize
        cfg.block_size = UInt32(blockDevice.blockSize)

        // Branch on `FSBlockDeviceResource.isWritable`: macOS opens removable
        // media (SD, USB) read-only by default unless the user mounts it
        // writable. Calling fs_ext4_mount_rw_with_callbacks against a
        // read-only resource produces "Bad file descriptor" on the first
        // metadata write during journal replay and the mount aborts. Fall
        // back to the v0.1.2 read-only entry point in that case so the user
        // still gets a working (read-only) volume.
        let isWritable = blockDevice.isWritable
        let bridgeFS: OpaquePointer?
        if isWritable {
            dlog.info("calling fs_ext4_mount_rw_with_callbacks_lazy (deferred journal replay) size=\(cfg.size_bytes) blocksize=\(cfg.block_size)")
            bridgeFS = fs_ext4_mount_rw_with_callbacks_lazy(&cfg)
        } else {
            dlog.info("resource is not writable — falling back to fs_ext4_mount_with_callbacks (RO) size=\(cfg.size_bytes) blocksize=\(cfg.block_size)")
            bridgeFS = fs_ext4_mount_with_callbacks(&cfg)
        }

        guard let bridgeFS = bridgeFS else {
            let err = fs_ext4_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
            dlog.error("mount failed in fs_ext4 (\(isWritable ? "rw" : "ro")): \(err)")
            Unmanaged<BlockDeviceContext>.fromOpaque(contextPtr).release()
            replyHandler(nil, POSIXError(.EIO))
            return
        }
        dlog.info("fs_ext4 mount succeeded (\(isWritable ? "rw, replay deferred" : "ro"))")

        let backend = EXT4Backend(bridgeFS: bridgeFS)
        // Stash backend + bsdName so `startCheck(task:options:)` (which
        // FSKit calls without a resource handle) can find them.
        Self.mountedResources.withLock { map in
            map[ObjectIdentifier(resource)] = MountedResource(
                bsdName: bsdName, backend: backend)
        }
        let volInfo = backend.volumeInfo()
        let volID = FSVolume.Identifier()
        let volume = EXT4Volume(
            volumeID: volID,
            volumeName: FSFileName(string: volInfo.name),
            backend: backend,
            blockDeviceContext: contextPtr,
            requiresJournalReplay: isWritable,
            stats: stats
        )
        // Begin emitting `io.stats` heartbeats now that the volume
        // exists. The collector self-suppresses idle ticks.
        stats.start()

        containerStatus = .ready
        dlog.info("volume ready: \"\(volInfo.name)\" blocks=\(volInfo.totalBlocks) free=\(volInfo.freeBlocks) dirty=\(volInfo.mountedDirty)")
        // Emit one compact event with volume-identity + sizing so the host
        // app can populate the detail pane without re-parsing the text log.
        dlog.event(kind: "volume.info", fields: [
            "fs": "ext4",
            "volume_name": volInfo.name,
            "block_size": "\(volInfo.blockSize)",
            "total_blocks": "\(volInfo.totalBlocks)",
            "free_blocks": "\(volInfo.freeBlocks)",
            "total_inodes": "\(volInfo.totalInodes)",
            "free_inodes": "\(volInfo.freeInodes)",
        ], scope: AppLogScope.volume)
        // Surface the clean/dirty signal read by the Rust driver (from
        // s_state before any journal replay). ext4's journal replay is
        // automatic inside fs_ext4_mount_with_callbacks, so the event is
        // informational — no follow-up fsck required.
        dlog.event(kind: volInfo.mountedDirty ? "volume.dirty" : "volume.clean",
                   fields: [:], scope: AppLogScope.volume)
        replyHandler(volume, nil)
    }

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        log.info("unloadResource called", scope: AppLogScope.lifecycle)
        Self.mountedResources.withLock { map in
            map.removeValue(forKey: ObjectIdentifier(resource))
        }
        reply(nil)
    }

    func didFinishLoading() {
    }
}

extension EXT4FileSystem: FSManageableResourceMaintenanceOperations {
    /// Run an ext4 fsck pass driven by the Rust crate's
    /// `fs_ext4_fsck_run`. Emits NDJSON events the host app's
    /// `AttachedDisksModel` consumes: `fsck.start`, `fsck.progress`,
    /// `fsck.done`, `fsck.failed`.
    ///
    /// We use a detached `Task` rather than running synchronously
    /// because FSKit expects `startCheck` to return a `Progress`
    /// immediately and have us call `task.didComplete(error:)` once
    /// the work is finished — exactly what NSProgress + an async tail
    /// is for.
    ///
    /// `FSManageableResourceMaintenanceOperations` does NOT pass us a
    /// resource handle (see header comment on `mountedResources`).
    /// Since `FSUnaryFileSystem` instances host one mount at a time
    /// during their lifetime, we resolve the mount by reading the
    /// single entry from `mountedResources`. If multiple are ever
    /// registered (hypothetical multi-volume FSKit future) we fail
    /// loudly rather than guess.
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        let resolved: MountedResource? = Self.mountedResources.withLock { map in
            // Single registered mount → use it. Empty map → caller
            // invoked fsck before any volume was loaded; surface as
            // EBADF. Multiple → ambiguous, surface as EINVAL.
            guard !map.isEmpty else { return nil }
            if map.count == 1 { return map.values.first }
            return nil
        }

        guard let resolved = resolved else {
            log.error("startCheck: no (or ambiguous) mounted resource registered — refusing", scope: AppLogScope.fsck)
            throw POSIXError(.EBADF)
        }
        let bsdName = resolved.bsdName
        let backend = resolved.backend
        let dlog = TaggedLogger(
            log, fields: ["bsd": bsdName], kind: "ext4.fsck",
            scope: AppLogScope.fsck
        )

        // Pin Progress at 100 total units; the tracker bumps
        // `completedUnitCount` per phase as the Rust crate reports.
        // The Rust fsck has no cancel hook, so we don't wire a
        // `cancellationHandler` — partition cancel from FSKit's UI
        // would be best-effort no-op.
        let progress = Progress(totalUnitCount: 100)

        dlog.event(kind: "fsck.start", fields: [:])

        // "directory" dominates because that's where the Rust crate
        // walks every entry and reports `done`/`total` against that
        // workload — see `FsckProgressTracker` for the full slicing.
        let tracker = FsckProgressTracker()

        // Detached so the closure isn't tied to any actor; the C
        // callbacks fire on Rust's worker thread anyway.
        Task.detached {
            let result = backend.runFsck(
                onProgress: { phase, done, total in
                    // Emit the structured event verbatim — the host
                    // app's `AttachedDisksModel` consumes phase/done/
                    // total directly.
                    dlog.event(kind: "fsck.progress", fields: [
                        "phase": phase,
                        "done":  "\(done)",
                        "total": "\(total)",
                    ])
                    // Compute and apply progress. NSProgress is
                    // thread-safe for `completedUnitCount` writes;
                    // KVO observers receive notifications on the
                    // posting thread, which UI code on the host side
                    // hops to the main queue itself.
                    let units = tracker.observe(
                        phase: phase, done: done, total: total)
                    progress.completedUnitCount = units
                },
                onFinding: { f in
                    // Findings are noisy diagnostic detail — surface
                    // them as plain WARN log lines so they appear in
                    // the partition log strip, not the fsck status
                    // pill.
                    dlog.warn("fsck finding: kind=\(f.kind) inode=\(f.inode) \(f.detail)")
                }
            )

            switch result {
            case .success(let report):
                dlog.event(kind: "fsck.done", fields: [
                    "dirty_cleared": report.dirtyCleared ? "true" : "false",
                    "logfile_bytes": "0",
                    "anomalies":     "\(report.anomaliesFound)",
                    "directories":   "\(report.directoriesScanned)",
                    "inodes":        "\(report.inodesVisited)",
                ])
                progress.completedUnitCount = 100
                task.didComplete(error: nil)

            case .failure(let err):
                dlog.event(kind: "fsck.failed", fields: [
                    "error": "\(err)",
                ])
                task.didComplete(error: err)
            }
        }

        return progress
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        throw POSIXError(.ENOSYS)
    }
}

/// Maps the Rust crate's phase/done/total stream onto a 0-100
/// `NSProgress.completedUnitCount`. Each known phase contributes a
/// fixed slice; unknown phase names contribute zero. Phase changes
/// are monotonic (the Rust crate completes phases in order), so once
/// a new phase appears we credit the full weight of all prior ones
/// regardless of intra-phase progress.
///
/// Lock guards the mutable cursor so callbacks fired from the Rust
/// thread are serialised against any future caller. We use
/// `OSAllocatedUnfairLock` for consistency with the rest of this
/// extension; the critical section is purely arithmetic.
final class FsckProgressTracker: @unchecked Sendable {
    private struct State {
        var lastPhase: String = ""
        var completedFloor: Int64 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    private static let totalUnits: Int64 = 100
    private static let phaseWeight: [String: Int64] = [
        "superblock": 5,
        "journal":    10,
        "directory":  60,
        "inodes":     20,
        "finalize":   5,
    ]

    func observe(phase: String, done: UInt64, total: UInt64) -> Int64 {
        return state.withLock { s -> Int64 in
            if phase != s.lastPhase {
                if !s.lastPhase.isEmpty {
                    s.completedFloor += Self.phaseWeight[s.lastPhase] ?? 0
                }
                s.lastPhase = phase
            }
            let weight = Self.phaseWeight[phase] ?? 0
            let intra: Int64
            if total == 0 {
                intra = 0
            } else {
                let ratio = max(0.0, min(1.0, Double(done) / Double(total)))
                intra = Int64(Double(weight) * ratio)
            }
            return min(Self.totalUnits, s.completedFloor + intra)
        }
    }
}
