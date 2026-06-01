/*
 * EXT4FileSystem.swift — FSKit filesystem module for ext4.
 * Pattern matched from KhaosT/FSKitSample (macOS 26 compatible).
 */

import FSKit
import Foundation
import DiskJockeyLibrary

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
/// Common interface for both block-device and file-backed I/O contexts.
/// Allows detectContainer and the fs_core callback closures to be written once
/// and dispatched to whichever concrete context is in use at load time.
protocol DeviceReadable: AnyObject {
    func read(into buf: UnsafeMutableRawPointer, offset: off_t, length: Int) -> Int32
}

/// Minimum sector size guaranteed by ATA/NVMe spec; used as the
/// floor when the device reports 0 for its block size.
private let minSectorBytes = 512

final class BlockDeviceContext: DeviceReadable {
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
        let bs = max(blockSize, minSectorBytes)
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
        let bs = max(logicalBs, physicalBs, minSectorBytes)
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

/// File-backed I/O context for FSPathURLResource mounts.
/// Analogous to BlockDeviceContext but reads/writes a plain file via pread/pwrite.
/// Used when fskitd invokes `mount -F -t ext4 /path/to/file.qcow2 /Volumes/name`.
final class FileDeviceContext: DeviceReadable {
    let fileURL: URL
    let fileSize: UInt64
    let writable: Bool
    let log: TaggedLogger
    let stats: IOStatsCollector
    private let fd: Int32
    private let securityScoped: Bool

    init(url: URL, writable: Bool, log: TaggedLogger, stats: IOStatsCollector) throws {
        self.fileURL = url
        self.writable = writable
        self.log = log
        self.stats = stats
        self.securityScoped = url.startAccessingSecurityScopedResource()
        let flags: Int32 = writable ? O_RDWR : O_RDONLY
        let descriptor = Darwin.open(url.path, flags)
        guard descriptor >= 0 else {
            if securityScoped { url.stopAccessingSecurityScopedResource() }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }
        self.fd = descriptor
        var st = Darwin.stat()
        guard Darwin.fstat(descriptor, &st) == 0 else {
            Darwin.close(descriptor)
            if securityScoped { url.stopAccessingSecurityScopedResource() }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.fileSize = UInt64(bitPattern: Int64(st.st_size))
    }

    deinit {
        Darwin.close(fd)
        if securityScoped { fileURL.stopAccessingSecurityScopedResource() }
    }

    func read(into buf: UnsafeMutableRawPointer, offset: off_t, length: Int) -> Int32 {
        let t0 = monotonicNanos()
        let n = pread(fd, buf, length, offset)
        if n < 0 || n < length {
            log.error("file read short: off=\(offset) len=\(length) got=\(n)", scope: AppLogScope.io)
            stats.recordBdevRead(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
            return EIO
        }
        stats.recordBdevRead(bytes: length, latencyNs: monotonicNanos() &- t0, error: false)
        return 0
    }

    func write(from buf: UnsafeRawPointer, offset: off_t, length: Int) -> Int32 {
        let t0 = monotonicNanos()
        let n = pwrite(fd, buf, length, offset)
        if n < 0 || n < length {
            log.error("file write short: off=\(offset) len=\(length) got=\(n)", scope: AppLogScope.io)
            stats.recordBdevWrite(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
            return EIO
        }
        stats.recordBdevWrite(bytes: length, latencyNs: monotonicNanos() &- t0, error: false)
        return 0
    }

    func flush() -> Int32 {
        return Darwin.fsync(fd) == 0 ? 0 : EIO
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
    struct MountedResource: DiskJockeyLibrary.MountedResource {
        let bsdName: String
        let backend: EXT4Backend
        /// Retained `BlockDeviceContext` pointer for block-device mounts;
        /// nil for file-backed (FSPathURLResource) mounts where startFormat
        /// is not supported. Used by startFormat to rebuild the blockdev cfg.
        let contextPtr: UnsafeMutableRawPointer?
        /// Cooperative tri-state mutex coordinating verify (`startCheck`)
        /// and repair (`RepairXPCService`) so both can't run on the
        /// same mounted volume concurrently. Default `.idle` ⇒
        /// filesystem is available for normal operations. See
        /// `OperationLock` for the contract.
        let opLock: OperationLock
    }
    static let mountedResources = MountedResourceRegistry<MountedResource>()

    /// Shared parent-death watchdog for fsck / repair / format. See
    /// `DetachedOperationWatchdog` for the rationale. The `onExpire`
    /// closure logs + exits the process so `storagekitd` respawns the
    /// appex cleanly.
    static let watchdog: DetachedOperationWatchdog = {
        // Fix D — stuck-progress monitor. If `heartbeat()` doesn't
        // fire for `stuckDeadline` seconds while at least one op
        // is in flight, the op is presumed wedged (e.g. fsck stuck
        // on a corrupted inode loop) and the appex `exit`s the
        // same way deactivate-watchdog does. Default 60 s,
        // overridable via the App Group default
        // `ext4StuckDeadlineSeconds` (read once at static-let init
        // time, same one-shot pattern as the deactivate side's
        // `ext4WatchdogDeadlineSeconds` override).
        let defaults = UserDefaults(suiteName: AppLog.groupIdentifier)
        let configuredStuck = defaults?.double(forKey: "ext4StuckDeadlineSeconds") ?? 0
        let stuckDeadline: TimeInterval = configuredStuck > 0 ? configuredStuck : 60
        return DetachedOperationWatchdog(
            label: "ext4",
            defaultDeadline: 30,
            stuckDeadline: stuckDeadline
        ) { pending, deadline in
            log.error(
                "watchdog: \(pending) op(s) still pending after \(Int(deadline))s — exiting (EX_TEMPFAIL) so storagekitd respawns",
                scope: AppLogScope.lifecycle
            )
            exit(Int32(EX_TEMPFAIL))
        }
    }()

    /// Thin wrappers preserved so call sites (this file, RepairXPCService)
    /// don't need to know about the underlying class.
    static func enterOperation() { watchdog.enter() }
    static func exitOperation() { watchdog.leave() }

    /// Called from `EXT4Volume.deactivate` after the volume's normal
    /// teardown. Consults the App Group default
    /// `ext4WatchdogDeadlineSeconds` to allow runtime extension for
    /// slow-disk diagnostics without recompiling.
    static func scheduleWatchdogIfNeeded() {
        let defaults = UserDefaults(suiteName: AppLog.groupIdentifier)
        let configured = defaults?.double(forKey: "ext4WatchdogDeadlineSeconds") ?? 0
        let deadline: TimeInterval? = configured > 0 ? configured : nil
        let pending = watchdog.pending
        let scheduled = watchdog.scheduleExpiryIfNeeded(deadline: deadline)
        if scheduled {
            let effective = deadline ?? watchdog.defaultDeadline
            log.warn(
                "deactivate: \(pending) detached op(s) still in flight; watchdog will exit appex in \(Int(effective))s if not done",
                scope: AppLogScope.lifecycle
            )
        }
    }

    override init() {
        super.init()
        // One mach-service listener per process — guarded inside start().
        // Vends in-process repair to the host app via NSXPCConnection;
        // see RepairXPCService for the rationale.
        RepairXPCService.shared.start()
    }


    func probeResource(
        resource: FSResource,
        replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        log.info("probe called", scope: AppLogScope.probe)

        if let fileResource = resource as? FSPathURLResource {
            probeFileResource(fileResource, replyHandler: replyHandler)
            return
        }

        guard let blockDevice = resource as? FSBlockDeviceResource else {
            log.warn("probe: unsupported resource type — not recognized", scope: AppLogScope.probe)
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

        if let fileResource = resource as? FSPathURLResource {
            loadFileResource(fileResource, resource: resource, options: options, replyHandler: replyHandler)
            return
        }

        guard let blockDevice = resource as? FSBlockDeviceResource else {
            log.error("loadResource: unsupported resource type — EINVAL", scope: AppLogScope.lifecycle)
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
        // Wrap the per-mount logger as the recorder's emit closure so
        // the shared `IOStatsRecorder` (in DiskJockeyLibrary) doesn't
        // need to import any logger type — AppLog stays per-extension.
        let stats = IOStatsRecorder(label: bsdName, emit: { fields in
            dlog.event(kind: "io.stats", fields: fields, scope: AppLogScope.stats)
        })
        let context = BlockDeviceContext(resource: blockDevice, log: dlog, stats: stats)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        // Detect a known disk-image container at offset 0 (QCOW2,
        // VHDX, VMDK, dynamic/differencing VHD) or at the trailing
        // 512-byte footer (fixed VHD). When matched, we don't hand
        // the resource directly to fs_ext4 — instead we lift it to
        // an FsCoreDevice via fs_core_device_from_callbacks, stack
        // the appropriate container reader on top, and mount ext4
        // on the resulting *virtual* device. The container reader
        // translates every virtual-offset I/O into the right
        // physical lookup.
        let containerKind = Self.detectContainer(context: context,
                                                 sizeBytes: blockDevice.blockCount * blockDevice.blockSize)
        // Partition-aware mount: when the host attached this resource
        // for a specific partition, it passes `partition_offset=N` +
        // `partition_length=M` task options. We slice the
        // (possibly container-wrapped) device at that range and mount
        // ext4 on the slice. Without these options, we mount the whole
        // device as today (single-FS image).
        let argv = options.taskOptions
        let partitionOffset: UInt64? = Self.taskOption("partition_offset", from: argv) { UInt64($0) }
        let partitionLength: UInt64? = Self.taskOption("partition_length", from: argv) { UInt64($0) }
        let isWritable = blockDevice.isWritable
        let bridgeFS: OpaquePointer?

        if partitionOffset != nil || partitionLength != nil {
            dlog.info("partition mount requested: offset=\(partitionOffset ?? 0) length=\(partitionLength ?? 0) container=\(containerKind.map(String.init(describing:)) ?? "raw")")
        }

        // Lift to fs_core whenever any of (container, partition slice)
        // applies — both shape changes need the FsCoreDevice handle
        // chain. The historical "direct callback mount" path stays as
        // the fallback for plain whole-disk ext4 images.
        let needsFsCorePath = (containerKind != nil) || (partitionOffset != nil) || (partitionLength != nil)

        if needsFsCorePath {
            dlog.info("fs_core mount path: container=\(containerKind.map(String.init(describing:)) ?? "raw") partition_offset=\(partitionOffset ?? 0) partition_length=\(partitionLength ?? 0) writable=\(isWritable)")
            do {
                let mountHandle = try Self.buildFsCoreHandle(
                    contextPtr: contextPtr,
                    sizeBytes: blockDevice.blockCount * blockDevice.blockSize,
                    isWritable: isWritable,
                    containerKind: containerKind,
                    partitionOffset: partitionOffset,
                    partitionLength: partitionLength,
                    dlog: dlog
                )
                // fs_ext4_mount_*_fs_core_device_* clones an Arc<dyn BlockDevice>
                // from the handle, so closing mountHandle afterwards is safe.
                dlog.info("calling fs_ext4_mount_with_fs_core_device\(isWritable ? "_lazy" : "")")
                bridgeFS = isWritable
                    ? fs_ext4_mount_with_fs_core_device_lazy(mountHandle)
                    : fs_ext4_mount_with_fs_core_device(mountHandle)
                fs_core_device_close(mountHandle)
            } catch {
                Unmanaged<BlockDeviceContext>.fromOpaque(contextPtr).release()
                replyHandler(nil, error)
                return
            }
        } else {
            // Direct ext4 mount: callbacks point at BlockDeviceContext, no
            // container layer in between. This is the historical path.
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
            if isWritable {
                dlog.info("calling fs_ext4_mount_rw_with_callbacks_lazy (deferred journal replay) size=\(cfg.size_bytes) blocksize=\(cfg.block_size)")
                bridgeFS = fs_ext4_mount_rw_with_callbacks_lazy(&cfg)
            } else {
                dlog.info("resource is not writable — falling back to fs_ext4_mount_with_callbacks (RO) size=\(cfg.size_bytes) blocksize=\(cfg.block_size)")
                bridgeFS = fs_ext4_mount_with_callbacks(&cfg)
            }
        }

        guard let bridgeFS = bridgeFS else {
            let err = fs_ext4_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
            let suffix = containerKind.map { ", \($0)" } ?? ""
            dlog.error("mount failed in fs_ext4 (\(isWritable ? "rw" : "ro")\(suffix)): \(err)")
            Unmanaged<BlockDeviceContext>.fromOpaque(contextPtr).release()
            replyHandler(nil, POSIXError(.EIO))
            return
        }
        let suffix = containerKind.map { ", \($0)-backed" } ?? ""
        dlog.info("fs_ext4 mount succeeded (\(isWritable ? "rw, replay deferred" : "ro")\(suffix))")

        let backend = EXT4Backend(bridgeFS: bridgeFS)
        // Stash backend + bsdName + contextPtr so `startCheck` and
        // `startFormat` (both called without a resource handle) can
        // find them. The contextPtr lifecycle matches the volume's;
        // the EXT4Volume releases it in `deactivate`.
        // Single OperationLock instance shared between the
        // MountedResource record (consulted by startCheck +
        // RepairXPCService) and the EXT4Volume (consulted as a
        // pre-flight EBUSY guard on every user-facing FS op).
        // The lock IS the quiesce: when it's non-idle, no caller
        // outside the holder may read or write the volume.
        let opLock = OperationLock()
        Self.mountedResources.register(resource, MountedResource(
            bsdName: bsdName, backend: backend,
            contextPtr: contextPtr, opLock: opLock))
        let volInfo = backend.volumeInfo()
        let volID = FSVolume.Identifier()
        let volume = EXT4Volume(
            volumeID: volID,
            volumeName: FSFileName(string: volInfo.name),
            backend: backend,
            blockDeviceContext: contextPtr,
            requiresJournalReplay: isWritable,
            stats: stats,
            opLock: opLock
        )
        // Begin emitting `io.stats` heartbeats now that the volume
        // exists. The collector self-suppresses idle ticks.
        stats.start()

        containerStatus = .ready
        dlog.info("volume ready: \"\(volInfo.name)\" blocks=\(volInfo.totalBlocks) free=\(volInfo.freeBlocks) dirty=\(volInfo.mountedDirty)")
        // Emit a compact event with everything the rust crate handed
        // back from the on-disk superblock. The host app's
        // AttachedDisksModel ingests these into the detail-pane "Volume
        // info" section, and `volume_uuid` drives stableIdentity for
        // sidebar coalescing across replug + app restart.
        var infoFields: [String: String] = [
            "fs": "ext4",
            "volume_name": volInfo.name,
            "block_size": "\(volInfo.blockSize)",
            "total_blocks": "\(volInfo.totalBlocks)",
            "free_blocks": "\(volInfo.freeBlocks)",
            "total_inodes": "\(volInfo.totalInodes)",
            "free_inodes": "\(volInfo.freeInodes)",
        ]
        if let v = volInfo.uuid                   { infoFields["volume_uuid"]      = v }
        if let v = volInfo.lastMounted            { infoFields["last_mounted"]     = v }
        if let v = volInfo.reservedBlocks         { infoFields["reserved_blocks"]  = "\(v)" }
        if let v = volInfo.inodeSize              { infoFields["inode_size"]       = "\(v)" }
        if let v = volInfo.firstInode             { infoFields["first_inode"]      = "\(v)" }
        if let v = volInfo.blocksPerGroup         { infoFields["blocks_per_group"] = "\(v)" }
        if let v = volInfo.inodesPerGroup         { infoFields["inodes_per_group"] = "\(v)" }
        if let v = volInfo.creatorOS              { infoFields["creator_os"]       = Self.formatCreatorOS(v) }
        if let v = volInfo.revLevel               { infoFields["revision_level"]   = "\(v)" }
        if let v = volInfo.minorRevLevel          { infoFields["minor_rev_level"]  = "\(v)" }
        if let v = volInfo.featureCompat          { infoFields["features_compat"]    = Self.formatFeatureFlags(v, kind: .compat) }
        if let v = volInfo.featureIncompat        { infoFields["features_incompat"]  = Self.formatFeatureFlags(v, kind: .incompat) }
        if let v = volInfo.featureRoCompat        { infoFields["features_ro_compat"] = Self.formatFeatureFlags(v, kind: .roCompat) }
        if let v = volInfo.descSize               { infoFields["desc_size"]        = "\(v)" }
        if let v = volInfo.state                  { infoFields["state"]            = Self.formatState(v) }
        if let v = volInfo.errorsBehavior         { infoFields["errors_behavior"]  = Self.formatErrorsBehavior(v) }
        if let v = volInfo.lastMountTime          { infoFields["last_mount_time"]  = "\(v)" }
        if let v = volInfo.lastWriteTime          { infoFields["last_write_time"]  = "\(v)" }
        if let v = volInfo.lastCheckTime          { infoFields["last_check_time"]  = "\(v)" }
        if let v = volInfo.checkInterval          { infoFields["check_interval"]   = "\(v)" }
        if let v = volInfo.mountCount             { infoFields["mount_count"]      = "\(v)" }
        if let v = volInfo.maxMountCount          { infoFields["max_mount_count"]  = "\(v)" }
        dlog.event(kind: "volume.info", fields: infoFields, scope: AppLogScope.volume)
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
        Self.mountedResources.remove(resource)
        reply(nil)
    }

    func didFinishLoading() {
    }

    // MARK: - Container detection helpers

    /// Disk-image container kinds we know how to unwrap onto an
    /// FsCoreDevice before mounting ext4 on the resulting virtual
    /// device. Mirrored on the NTFS side (NTFSFileSystem.swift).
    enum ContainerKind: String, CustomStringConvertible {
        case qcow2, vhd, vhdx, vmdk
        var description: String { rawValue }

        static let qcow2Magic: [UInt8]    = [0x51, 0x46, 0x49, 0xFB]              // "QFI\xFB"
        static let vhdxMagic: [UInt8]    = [0x76, 0x68, 0x64, 0x78,
                                             0x66, 0x69, 0x6c, 0x65]             // "vhdxfile"
        static let vmdkMagic: [UInt8]    = [0x4b, 0x44, 0x4d, 0x56]             // "KDMV" (LE "VMDK")
        static let conectixMagic: [UInt8] = [0x63, 0x6f, 0x6e, 0x65,
                                              0x63, 0x74, 0x69, 0x78]            // "conectix" VHD footer
        /// Fixed VHD format places the conectix footer in the last 512 bytes.
        static let vhdFixedFooterOffset: Int = 512
    }

    /// Probe for a known container magic using any DeviceReadable context.
    /// Returns nil for raw partition images (fs_ext4 handles those directly).
    static func detectContainer<C: DeviceReadable>(context: C, sizeBytes: UInt64) -> ContainerKind? {
        var head = [UInt8](repeating: 0, count: 16)
        let rc = head.withUnsafeMutableBufferPointer { buf -> Int32 in
            context.read(into: buf.baseAddress!, offset: 0, length: 16)
        }
        if rc == 0 {
            if Array(head.prefix(4)) == ContainerKind.qcow2Magic   { return .qcow2 }
            if Array(head.prefix(8)) == ContainerKind.vhdxMagic    { return .vhdx }
            if Array(head.prefix(4)) == ContainerKind.vmdkMagic    { return .vmdk }
            if Array(head.prefix(8)) == ContainerKind.conectixMagic { return .vhd }
        }
        if sizeBytes >= ContainerKind.vhdFixedFooterOffset {
            var footer = [UInt8](repeating: 0, count: 8)
            let frc = footer.withUnsafeMutableBufferPointer { buf -> Int32 in
                context.read(into: buf.baseAddress!, offset: off_t(sizeBytes) - off_t(ContainerKind.vhdFixedFooterOffset), length: 8)
            }
            if frc == 0 && footer == ContainerKind.conectixMagic { return .vhd }
        }
        return nil
    }

    // MARK: - File resource (FSPathURLResource) probe + load

    private func probeFileResource(
        _ resource: FSPathURLResource,
        replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        let url = resource.url
        let dlog = TaggedLogger(log, fields: ["file": url.lastPathComponent],
                                kind: "ext4.probe", scope: AppLogScope.probe)
        dlog.info("probe FSPathURLResource: \(url.path)")

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else {
            dlog.warn("probe: cannot open file (errno=\(errno)) — not recognized")
            replyHandler(.notRecognized, nil)
            return
        }
        defer { Darwin.close(fd) }

        // Check for known container magic at offset 0
        var hdr = [UInt8](repeating: 0, count: 16)
        let n = hdr.withUnsafeMutableBufferPointer { buf in pread(fd, buf.baseAddress!, 16, 0) }
        if n >= 8 {
            if Array(hdr.prefix(4)) == ContainerKind.qcow2Magic {
                dlog.info("probe: qcow2 container → usable as ext4")
                replyHandler(.usable(name: "ext4", containerID: FSContainerIdentifier(uuid: UUID())), nil)
                return
            }
            if Array(hdr.prefix(8)) == ContainerKind.vhdxMagic {
                dlog.info("probe: vhdx container → usable as ext4")
                replyHandler(.usable(name: "ext4", containerID: FSContainerIdentifier(uuid: UUID())), nil)
                return
            }
            if Array(hdr.prefix(8)) == ContainerKind.conectixMagic {
                dlog.info("probe: vhd (dynamic) → usable as ext4")
                replyHandler(.usable(name: "ext4", containerID: FSContainerIdentifier(uuid: UUID())), nil)
                return
            }
            if Array(hdr.prefix(4)) == ContainerKind.vmdkMagic {
                dlog.info("probe: vmdk container → usable as ext4")
                replyHandler(.usable(name: "ext4", containerID: FSContainerIdentifier(uuid: UUID())), nil)
                return
            }
        }

        // Fixed VHD: "conectix" in the last vhdFixedFooterOffset bytes
        var st = Darwin.stat()
        if Darwin.fstat(fd, &st) == 0 && st.st_size >= ContainerKind.vhdFixedFooterOffset {
            var footer = [UInt8](repeating: 0, count: 8)
            let fr = footer.withUnsafeMutableBufferPointer { buf in
                pread(fd, buf.baseAddress!, 8, off_t(st.st_size) - off_t(ContainerKind.vhdFixedFooterOffset))
            }
            if fr == 8 && footer == ContainerKind.conectixMagic {
                dlog.info("probe: vhd (fixed) footer → usable as ext4")
                replyHandler(.usable(name: "ext4", containerID: FSContainerIdentifier(uuid: UUID())), nil)
                return
            }
        }

        // Raw ext4 superblock at offset 1024 (need 136 bytes for name + UUID)
        var sb = [UInt8](repeating: 0, count: 136)
        let nr = sb.withUnsafeMutableBufferPointer { buf in pread(fd, buf.baseAddress!, 136, 1024) }
        guard nr >= 58 else {
            dlog.info("probe: file too small for ext4 superblock — not recognized")
            replyHandler(.notRecognized, nil)
            return
        }
        let magic = UInt16(sb[56]) | (UInt16(sb[57]) << 8)
        guard magic == 0xEF53 else {
            dlog.info("probe: no ext4 magic or known container — not recognized")
            replyHandler(.notRecognized, nil)
            return
        }
        let rawName = String(bytes: sb[120..<136].prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
        let volumeName = rawName.isEmpty ? "ext4" : rawName
        let uuidBytes = Array(sb[104..<120])
        let containerID = FSContainerIdentifier(uuid: NSUUID(uuidBytes: uuidBytes) as UUID)
        dlog.info("probe: raw ext4 superblock in file — volume \"\(volumeName)\"")
        replyHandler(.usable(name: volumeName, containerID: containerID), nil)
    }

    private func loadFileResource(
        _ fileResource: FSPathURLResource,
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        let url = fileResource.url
        let isWritable = fileResource.isWritable
        let label = url.lastPathComponent
        let dlog = TaggedLogger(log, fields: ["file": label],
                                kind: "ext4.load", scope: AppLogScope.lifecycle)
        dlog.info("loadResource file: \(url.path) writable=\(isWritable) taskOptions=\(options.taskOptions)")

        let stats = IOStatsRecorder(label: label, emit: { fields in
            dlog.event(kind: "io.stats", fields: fields, scope: AppLogScope.stats)
        })

        let context: FileDeviceContext
        do {
            context = try FileDeviceContext(url: url, writable: isWritable, log: dlog, stats: stats)
        } catch {
            dlog.error("loadResource: cannot open file — \(error.localizedDescription)")
            replyHandler(nil, error)
            return
        }

        // Retain the context as AnyObject so EXT4Volume.deactivate() can release it
        // via Unmanaged<AnyObject>.fromOpaque(ctx).release() without type-casting.
        let contextPtr = Unmanaged<AnyObject>.passRetained(context as AnyObject).toOpaque()

        let sizeBytes = context.fileSize
        let containerKind = Self.detectContainer(context: context, sizeBytes: sizeBytes)
        let argv = options.taskOptions
        let partitionOffset: UInt64? = Self.taskOption("partition_offset", from: argv) { UInt64($0) }
        let partitionLength: UInt64? = Self.taskOption("partition_length", from: argv) { UInt64($0) }

        dlog.info("file mount: size=\(sizeBytes) container=\(containerKind.map(String.init(describing:)) ?? "raw") offset=\(partitionOffset ?? 0) length=\(partitionLength ?? 0) writable=\(isWritable)")

        var coreCfg = FsCoreCallbackCfg()
        coreCfg.read = { ctx, offset, buf, len in
            guard let ctx = ctx, let buf = buf else { return EIO }
            return Unmanaged<FileDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                .read(into: UnsafeMutableRawPointer(buf), offset: off_t(offset), length: Int(len))
        }
        coreCfg.write = isWritable ? { ctx, offset, buf, len in
            guard let ctx = ctx, let buf = buf else { return EIO }
            return Unmanaged<FileDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                .write(from: UnsafeRawPointer(buf), offset: off_t(offset), length: Int(len))
        } : nil
        coreCfg.flush = { ctx in
            guard let ctx = ctx else { return EIO }
            return Unmanaged<FileDeviceContext>.fromOpaque(ctx).takeUnretainedValue().flush()
        }
        coreCfg.ctx = contextPtr
        coreCfg.size = sizeBytes

        guard let callbackHandle = withUnsafePointer(to: &coreCfg, { fs_core_device_from_callbacks($0) }) else {
            let err = fs_core_last_error_message().flatMap { String(cString: $0) } ?? "(no error set)"
            dlog.error("fs_core_device_from_callbacks failed: \(err)")
            Unmanaged<AnyObject>.fromOpaque(contextPtr).release()
            replyHandler(nil, POSIXError(.EIO))
            return
        }

        var stackedHandle: OpaquePointer = callbackHandle
        if let kind = containerKind {
            guard let h = Self.openContainer(kind: kind, inner: stackedHandle, writable: isWritable) else {
                let err = fs_core_last_error_message().flatMap { String(cString: $0) } ?? "(no error set)"
                dlog.error("\(kind)_open\(isWritable ? "_rw" : "")_on_device failed: \(err)")
                Unmanaged<AnyObject>.fromOpaque(contextPtr).release()
                replyHandler(nil, POSIXError(.EIO))
                return
            }
            stackedHandle = h
        }

        var mountHandle: OpaquePointer = stackedHandle
        var preMountClose: [OpaquePointer] = []
        if let offset = partitionOffset, let length = partitionLength, offset > 0 || length > 0 {
            guard let s = (isWritable
                            ? fs_core_device_slice_rw(stackedHandle, offset, length)
                            : fs_core_device_slice_ro(stackedHandle, offset, length)) else {
                let err = fs_core_last_error_message().flatMap { String(cString: $0) } ?? "(no error set)"
                dlog.error("fs_core_device_slice_\(isWritable ? "rw" : "ro") failed: \(err)")
                fs_core_device_close(stackedHandle)
                Unmanaged<AnyObject>.fromOpaque(contextPtr).release()
                replyHandler(nil, POSIXError(.EIO))
                return
            }
            preMountClose.append(stackedHandle)
            mountHandle = s
        }

        dlog.info("calling fs_ext4_mount_with_fs_core_device\(isWritable ? "_lazy" : "")")
        let bridgeFS = isWritable
            ? fs_ext4_mount_with_fs_core_device_lazy(mountHandle)
            : fs_ext4_mount_with_fs_core_device(mountHandle)
        fs_core_device_close(mountHandle)
        for h in preMountClose { fs_core_device_close(h) }

        guard let bridgeFS = bridgeFS else {
            let err = fs_ext4_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
            dlog.error("fs_ext4 file mount failed: \(err)")
            Unmanaged<AnyObject>.fromOpaque(contextPtr).release()
            replyHandler(nil, POSIXError(.EIO))
            return
        }
        let suffix = containerKind.map { ", \($0)-backed" } ?? ""
        dlog.info("fs_ext4 file mount succeeded (\(isWritable ? "rw, replay deferred" : "ro")\(suffix))")

        let backend = EXT4Backend(bridgeFS: bridgeFS)
        let opLock = OperationLock()
        // nil contextPtr in MountedResource: startFormat is not supported for file mounts
        // (no FSBlockDeviceResource to rebuild the format blockdev cfg against).
        Self.mountedResources.register(resource, MountedResource(
            bsdName: url.path, backend: backend,
            contextPtr: nil, opLock: opLock))

        let volInfo = backend.volumeInfo()
        let volID = FSVolume.Identifier()
        let volume = EXT4Volume(
            volumeID: volID,
            volumeName: FSFileName(string: volInfo.name),
            backend: backend,
            blockDeviceContext: contextPtr,  // held here so deactivate() releases FileDeviceContext
            requiresJournalReplay: isWritable,
            stats: stats,
            opLock: opLock
        )
        stats.start()

        containerStatus = .ready
        dlog.info("volume ready: \"\(volInfo.name)\" blocks=\(volInfo.totalBlocks) free=\(volInfo.freeBlocks) dirty=\(volInfo.mountedDirty)")
        var infoFields: [String: String] = [
            "fs": "ext4",
            "volume_name": volInfo.name,
            "block_size": "\(volInfo.blockSize)",
            "total_blocks": "\(volInfo.totalBlocks)",
            "free_blocks": "\(volInfo.freeBlocks)",
            "total_inodes": "\(volInfo.totalInodes)",
            "free_inodes": "\(volInfo.freeInodes)",
        ]
        if let v = volInfo.uuid { infoFields["volume_uuid"] = v }
        dlog.event(kind: "volume.info", fields: infoFields, scope: AppLogScope.volume)
        dlog.event(kind: volInfo.mountedDirty ? "volume.dirty" : "volume.clean",
                   fields: [:], scope: AppLogScope.volume)
        replyHandler(volume, nil)
    }

    /// Construct the right `*_open*_on_device` call for the kind +
    /// writability. Consumes `inner` — on NULL return the called
    /// function has already freed it per the C ABI contract.
    /// Build a FsCore device handle chain: callbacks → optional container → optional partition slice.
    /// The returned handle must be passed to `fs_ext4_mount_*` then closed with `fs_core_device_close`.
    /// Throws `POSIXError(.EIO)` on any step failure (caller releases contextPtr and calls replyHandler).
    static func buildFsCoreHandle(
        contextPtr: UnsafeMutableRawPointer,
        sizeBytes: UInt64,
        isWritable: Bool,
        containerKind: ContainerKind?,
        partitionOffset: UInt64?,
        partitionLength: UInt64?,
        dlog: TaggedLogger
    ) throws -> OpaquePointer {
        var coreCfg = FsCoreCallbackCfg()
        coreCfg.read = { ctx, offset, buf, len in
            guard let ctx = ctx, let buf = buf else { return EIO }
            return Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                .read(into: UnsafeMutableRawPointer(buf), offset: off_t(offset), length: Int(len))
        }
        coreCfg.write = isWritable ? { ctx, offset, buf, len in
            guard let ctx = ctx, let buf = buf else { return EIO }
            return Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                .write(from: UnsafeRawPointer(buf), offset: off_t(offset), length: Int(len))
        } : nil
        coreCfg.flush = { ctx in
            guard let ctx = ctx else { return EIO }
            return Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue().flush()
        }
        coreCfg.ctx = contextPtr
        coreCfg.size = sizeBytes

        guard let callbackHandle = withUnsafePointer(to: &coreCfg, { fs_core_device_from_callbacks($0) }) else {
            let err = fs_core_last_error_message().flatMap { String(cString: $0) } ?? "(no error set)"
            dlog.error("fs_core_device_from_callbacks failed: \(err)")
            throw POSIXError(.EIO)
        }

        // Stack container reader on top. Ownership of callbackHandle transfers to the container layer.
        var stackedHandle: OpaquePointer = callbackHandle
        if let kind = containerKind {
            guard let h = openContainer(kind: kind, inner: stackedHandle, writable: isWritable) else {
                let err = fs_core_last_error_message().flatMap { String(cString: $0) } ?? "(no error set)"
                dlog.error("\(kind)_open\(isWritable ? "_rw" : "")_on_device failed: \(err)")
                throw POSIXError(.EIO)
            }
            stackedHandle = h
        }

        // Slice to a partition range if requested. The slice borrows stackedHandle's Arc,
        // so we can close stackedHandle immediately — the slice keeps it alive.
        if let offset = partitionOffset, let length = partitionLength, offset > 0 || length > 0 {
            guard let slice = (isWritable
                                ? fs_core_device_slice_rw(stackedHandle, offset, length)
                                : fs_core_device_slice_ro(stackedHandle, offset, length)) else {
                let err = fs_core_last_error_message().flatMap { String(cString: $0) } ?? "(no error set)"
                dlog.error("fs_core_device_slice_\(isWritable ? "rw" : "ro") failed: \(err)")
                fs_core_device_close(stackedHandle)
                throw POSIXError(.EIO)
            }
            fs_core_device_close(stackedHandle)
            return slice
        }
        return stackedHandle
    }

    static func openContainer(kind: ContainerKind,
                              inner: OpaquePointer,
                              writable: Bool) -> OpaquePointer? {
        switch kind {
        case .qcow2: return writable ? qcow2_open_rw_on_device(inner) : qcow2_open_on_device(inner)
        case .vhd:   return writable ? vhd_open_rw_on_device(inner)   : vhd_open_on_device(inner)
        case .vhdx:  return writable ? vhdx_open_rw_on_device(inner)  : vhdx_open_on_device(inner)
        case .vmdk:  return writable ? vmdk_open_rw_on_device(inner)  : vmdk_open_on_device(inner)
        }
    }

    /// Parse a `key=value` mount option out of FSTaskOptions.taskOptions.
    /// `mount -F -t ext4 -o foo=1,bar=2 …` may surface either as one
    /// comma-separated string or as multiple entries depending on FSKit
    /// version; we handle both by splitting each entry on commas.
    static func taskOption<T>(_ name: String,
                              from argv: [String],
                              parser: (String) -> T?) -> T? {
        for raw in argv {
            for pair in raw.split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 && kv[0] == name {
                    if let v = parser(kv[1]) { return v }
                }
            }
        }
        return nil
    }

    /// Render the `s_creator_os` field. The ext4 spec defines five
    /// values; anything else gets the raw number so the user can look
    /// it up in `ext4.h` if it ever appears in the wild.
    static func formatCreatorOS(_ raw: UInt32) -> String {
        switch raw {
        case 0: return "Linux"
        case 1: return "Hurd"
        case 2: return "Masix"
        case 3: return "FreeBSD"
        case 4: return "Lites"
        default: return "unknown (\(raw))"
        }
    }

    /// Render `s_state` as a comma-separated bit list. Fresh filesystems
    /// read as "valid"; a kernel that detected errors leaves the
    /// `errors` bit set even after a remount.
    static func formatState(_ raw: UInt16) -> String {
        var parts: [String] = []
        if raw & 0x0001 != 0 { parts.append("valid") }
        if raw & 0x0002 != 0 { parts.append("errors") }
        if raw & 0x0004 != 0 { parts.append("orphan_recovery") }
        if parts.isEmpty { return "unknown (\(raw))" }
        return parts.joined(separator: ", ")
    }

    /// Render `s_errors`. The kernel uses this to decide what to do
    /// when it detects metadata corruption mid-operation.
    static func formatErrorsBehavior(_ raw: UInt16) -> String {
        switch raw {
        case 1: return "continue"
        case 2: return "remount read-only"
        case 3: return "panic"
        default: return "unknown (\(raw))"
        }
    }

    /// Pretty-print the three feature bitmaps as a comma-separated
    /// list of names. Caller passes the field tag ("compat",
    /// "incompat", "ro_compat") so we know which name table to use.
    /// Unknown bits surface as `bit-<n>` so nothing is silently lost.
    static func formatFeatureFlags(_ raw: UInt32, kind: FeatureKind) -> String {
        let names = kind.bitNames
        var out: [String] = []
        for i in 0..<32 where (raw & (UInt32(1) << i)) != 0 {
            if let n = names[i] { out.append(n) }
            else { out.append("bit-\(i)") }
        }
        return out.isEmpty ? "(none)" : out.joined(separator: ", ")
    }

    enum FeatureKind {
        case compat, incompat, roCompat

        /// Mapping from bit position → spec-defined feature name.
        /// Sourced from `linux/fs/ext4/ext4.h`; bits not yet defined
        /// stay nil and surface as `bit-<n>` to the user.
        var bitNames: [Int: String] {
            switch self {
            case .compat: return [
                0: "dir_prealloc", 1: "imagic_inodes", 2: "has_journal",
                3: "ext_attr", 4: "resize_inode", 5: "dir_index",
                6: "lazy_bg", 7: "exclude_inode", 8: "exclude_bitmap",
                9: "sparse_super2",
            ]
            case .incompat: return [
                0: "compression", 1: "filetype", 2: "recover",
                3: "journal_dev", 4: "meta_bg", 6: "extents",
                7: "64bit", 8: "mmp", 9: "flex_bg",
                10: "ea_inode", 12: "dirdata", 13: "csum_seed",
                14: "largedir", 15: "inline_data", 16: "encrypt",
                17: "casefold",
            ]
            case .roCompat: return [
                0: "sparse_super", 1: "large_file", 2: "btree_dir",
                3: "huge_file", 4: "gdt_csum", 5: "dir_nlink",
                6: "extra_isize", 7: "quota", 8: "bigalloc",
                9: "metadata_csum", 10: "replica", 11: "readonly",
                12: "project", 13: "verity", 14: "orphan_file",
            ]
            }
        }
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
        // Empty registry → caller invoked fsck before any volume was
        // loaded. Multiple entries → ambiguous (we assume one mount
        // per extension; surfacing as nil lets us refuse loudly
        // rather than guess which mount to verify).
        guard let resolved = Self.mountedResources.resolveSingle() else {
            log.error("startCheck: no (or ambiguous) mounted resource registered — refusing", scope: AppLogScope.fsck)
            throw POSIXError(.EBADF)
        }
        let bsdName = resolved.bsdName
        let backend = resolved.backend
        let opLock = resolved.opLock
        let dlog = TaggedLogger(
            log, fields: ["bsd": bsdName], kind: "ext4.fsck",
            scope: AppLogScope.fsck
        )

        // fsck_fskit validates module-option flags against the
        // extension's `FSCheckOptionSyntax` plist before forwarding,
        // so any flag we want to honour here MUST also be declared
        // there. We accept the BSD-style flags Apple's tools use:
        //   -y : repair without prompting (yes-to-all)
        //   -n : audit only, never write   (already the default)
        //   -q : quick check (currently treated as audit-only)
        // Plain argv contains/`-y` works because FSKit drops fsck_fskit's
        // canonical short options into taskOptions verbatim. The log
        // line surfaces both the raw argv and our derived intent so
        // future debugging doesn't require re-instrumenting.
        let argv = options.taskOptions
        let repairRequested = argv.contains("-y")

        // Cooperative tri-state mutex. Reject up front if the volume
        // is already being verified or repaired. The matching release
        // sits inside the Task.detached closure below so the lock
        // tracks the actual operation lifetime, not just this scope.
        let acquireOp: FsckOperation = repairRequested ? .repair : .verify
        if let busy = opLock.tryAcquire(acquireOp) {
            dlog.warn("startCheck rejected: volume busy with \(busy.displayName)")
            throw POSIXError(.EBUSY)
        }

        dlog.info("startCheck: bsd=\(bsdName) taskOptions=\(argv) repair=\(repairRequested)")
        dlog.event(kind: "fsck.start", fields: [
            "repair": repairRequested ? "true" : "false",
        ])

        // Pin Progress at 100 total units; the tracker bumps
        // `completedUnitCount` per phase as the Rust crate reports.
        // The Rust fsck has no cancel hook, so we don't wire a
        // `cancellationHandler` — partition cancel from FSKit's UI
        // would be best-effort no-op.
        let progress = Progress(totalUnitCount: 100)

        // "directory" dominates because that's where the Rust crate
        // walks every entry and reports `done`/`total` against that
        // workload — see `FsckProgressTracker` for the full slicing.
        let tracker = FsckProgressTracker()

        // Throttle fsck.progress emission. The Rust crate calls
        // onProgress once per directory walked + once per inode batch
        // — on a multi-thousand-dir volume that's thousands of
        // callbacks per second. Each emit lands on the host's main
        // actor (LogTailService → applyExtensionEvent → SwiftUI
        // rerender), so unthrottled emission floods the runloop and
        // beachballs the UI. NSProgress.completedUnitCount is updated
        // every callback (cheap KVO write), so the FSKit-side progress
        // bar stays smooth — only the structured event going to the
        // host is rate-limited. Mirror of the throttle in
        // RepairXPCService.
        let appGroupDefaults = UserDefaults(suiteName: AppLog.groupIdentifier)
        let verbose = appGroupDefaults?.bool(forKey: "verboseRepairLog") ?? false
        let minIntervalNs: UInt64 = verbose ? 100_000_000 : 1_000_000_000  // 10 Hz vs 1 Hz
        var lastEmitMonotonic: UInt64 = 0
        var lastPhase: String = ""

        // Detached so the closure isn't tied to any actor; the C
        // callbacks fire on Rust's worker thread anyway. The opLock
        // release happens here (not at the throw point) because the
        // operation continues asynchronously.
        //
        // Wrapped with `enter/exitOperation` so the parent-death
        // watchdog (see `scheduleWatchdogIfNeeded`) knows fsck is
        // still in flight if the mount tears down mid-pass.
        Self.enterOperation()
        Task.detached {
            defer {
                opLock.release()
                Self.exitOperation()
            }
            let result = backend.runFsck(
                repair: repairRequested,
                onProgress: { phase, done, total in
                    // Stuck-progress heartbeat. Tells the watchdog
                    // the op is still alive — must be unthrottled
                    // (called on every Rust progress callback) so a
                    // long quiet phase doesn't accidentally trip
                    // `stuckDeadline`.
                    Self.watchdog.heartbeat()
                    // Throttle. Phase change always emits (so the user
                    // sees the pipeline advance) and the first emit
                    // bypasses the time gate (so the progress bar
                    // appears immediately). All other emits are gated
                    // to the throttle interval.
                    let now = monotonicNanos()
                    let phaseChanged = phase != lastPhase
                    let intervalElapsed = lastEmitMonotonic == 0
                        || (now &- lastEmitMonotonic) >= minIntervalNs
                    if phaseChanged || intervalElapsed {
                        lastEmitMonotonic = now
                        lastPhase = phase
                        dlog.event(kind: "fsck.progress", fields: [
                            "phase": phase,
                            "done":  "\(done)",
                            "total": "\(total)",
                        ])
                    }
                    // Compute and apply progress. NSProgress is
                    // thread-safe for `completedUnitCount` writes;
                    // KVO observers receive notifications on the
                    // posting thread, which UI code on the host side
                    // hops to the main queue itself. We update this
                    // unconditionally — it's an atomic int64 write,
                    // not a UI rerender, so it doesn't contribute to
                    // the main-actor flood.
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
                dlog.event(kind: "fsck.done", fields: report.toEventFields())
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

    /// Start formatting the resource as ext4. Mirror of `startCheck`
    /// in shape: FSKit hands us a task + argv-style options but **no
    /// FSResource** (see `FSManageableResourceMaintenanceOperations`
    /// in the macOS 26 SDK headers). Same `mountedResources` map
    /// trick — find the single loaded device and operate on its
    /// `BlockDeviceContext`.
    ///
    /// **Current limitations** — captured in detail at
    /// `docs/fskit-format-pipeline.md`:
    /// 1. Disk MUST be loaded via `loadResource` first, otherwise we
    ///    throw `ENOTSUP`. Blank/raw disks (no recognized FS) never
    ///    load, so this path can't format them yet.
    /// 2. Formatting an actively-mounted volume corrupts the kernel
    ///    buffer cache. Caller is expected to unmount first; we don't
    ///    enforce it because the extension can't drive `diskutil` from
    ///    its sandbox.
    /// 3. The host-app side (`RawDiskDetailView`) is responsible for
    ///    the pre-format unmount + admin prompt + re-probe dance.
    ///
    /// The Rust `fs_ext4_mkfs` itself works correctly — round-trip
    /// tested, fsck.ext4 in CI confirms output is valid. The unsafe
    /// part is the *integration* with a live macOS mount, not the
    /// bytes we write.
    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        // Same single-mount-per-extension assumption as startCheck —
        // surface ambiguity loudly rather than guessing.
        guard let resolved = Self.mountedResources.resolveSingle() else {
            log.error(
                "startFormat: no loaded resource to format — disk must be probed/loaded first; see docs/fskit-format-pipeline.md",
                scope: AppLogScope.fsck
            )
            throw POSIXError(.ENOTSUP)
        }
        guard let resolvedContextPtr = resolved.contextPtr else {
            log.error("startFormat: not supported for file-backed mounts", scope: AppLogScope.fsck)
            throw POSIXError(.ENOTSUP)
        }
        let bsdName = resolved.bsdName
        let dlog = TaggedLogger(
            log, fields: ["bsd": bsdName], kind: "ext4.format",
            scope: AppLogScope.fsck
        )
        dlog.info("startFormat \(bsdName): taskOptions=\(options.taskOptions)")

        // Parse the `-L <label>` option if present in argv. We accept
        // it positionally because newfs_fskit forwards the user's CLI
        // args verbatim. No declared `FSFormatOptionSyntax` yet (would
        // be ideal — Apple's intended way) so we hand-parse.
        var label: String? = nil
        let argv = options.taskOptions
        if let idx = argv.firstIndex(of: "-L"), idx + 1 < argv.count {
            label = argv[idx + 1]
        }

        let progress = Progress(totalUnitCount: 100)
        dlog.event(kind: "format.start", fields: [
            "label": label ?? "",
        ])

        // Track in the parent-death watchdog counter — same rationale
        // as fsck. mkfs runs entirely inside the Rust crate with no
        // cancel hook, so if the mount goes away mid-format we want
        // the watchdog to exit the appex once the deadline elapses.
        Self.enterOperation()
        Task.detached {
            defer { Self.exitOperation() }
            // Build a fresh blockdev cfg pointing at the same
            // BlockDeviceContext the live mount is using. The cfg's
            // read/write/flush callbacks dispatch through the same C
            // shim as the mount path — so writes go through FSKit's
            // FSBlockDeviceResource just like a normal file write
            // would. Safety caveat: if the volume is mounted, the
            // kernel buffer cache is now stale. Unmount-after-format
            // is the user's responsibility (see doc).
            let bdc = resolvedContextPtr
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
            cfg.context = bdc
            // Pull size + block_size from the BlockDeviceContext's
            // resource; same values the original cfg used at load.
            let context = Unmanaged<BlockDeviceContext>.fromOpaque(bdc).takeUnretainedValue()
            cfg.size_bytes = UInt64(context.resource.blockCount * context.resource.blockSize)
            cfg.block_size = UInt32(context.resource.blockSize)

            // Convert label to a C string. Truncate to 16 bytes (ext4
            // superblock max). nil-safe — fs_ext4_mkfs accepts NULL.
            let labelCString = label?.cString(using: .utf8)
            let rc = labelCString?.withUnsafeBufferPointer { cbuf in
                fs_ext4_mkfs(&cfg, cbuf.baseAddress, nil)
            } ?? fs_ext4_mkfs(&cfg, nil, nil)

            if rc == 0 {
                dlog.event(kind: "format.done", fields: [:])
                progress.completedUnitCount = 100
                task.didComplete(error: nil)
            } else {
                let err = fs_ext4_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
                dlog.event(kind: "format.failed", fields: ["error": err], level: .error)
                task.didComplete(error: POSIXError(.EIO))
            }
        }

        return progress
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

// MARK: - MountableFileSystem conformance

/// Declares this extension as a DiskJockey FSKit filesystem so the
/// shared registry surface (`MountedResourceRegistry`) is reachable
/// generically. The associated `Resource` type is inferred from the
/// `static let mountedResources` declaration above.
extension EXT4FileSystem: MountableFileSystem {}
