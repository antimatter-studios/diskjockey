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
    struct MountedResource {
        let bsdName: String
        let backend: EXT4Backend
        /// Retained `BlockDeviceContext` pointer the load path used to
        /// drive the FSBlockDeviceResource via C callbacks. Carried so
        /// `startFormat` can build a fresh `fs_ext4_blockdev_cfg_t`
        /// against the same device without going through the backend
        /// (which is mid-mount and has its own lock semantics).
        let contextPtr: UnsafeMutableRawPointer
        /// Cooperative tri-state mutex coordinating verify (`startCheck`)
        /// and repair (`RepairXPCService`) so both can't run on the
        /// same mounted volume concurrently. Default `.idle` ⇒
        /// filesystem is available for normal operations. See
        /// `OperationLock` for the contract.
        let opLock: OperationLock
    }
    static let mountedResources = OSAllocatedUnfairLock<[ObjectIdentifier: MountedResource]>(
        initialState: [:])

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

            var coreCfg = FsCoreCallbackCfg()
            coreCfg.read = { ctx, offset, buf, len in
                guard let ctx = ctx, let buf = buf else { return EIO }
                let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                return context.read(into: UnsafeMutableRawPointer(buf), offset: off_t(offset), length: Int(len))
            }
            coreCfg.write = isWritable ? { ctx, offset, buf, len in
                guard let ctx = ctx, let buf = buf else { return EIO }
                let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                return context.write(from: UnsafeRawPointer(buf), offset: off_t(offset), length: Int(len))
            } : nil
            coreCfg.flush = { ctx in
                guard let ctx = ctx else { return EIO }
                let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                return context.flush()
            }
            coreCfg.ctx = contextPtr
            coreCfg.size = blockDevice.blockCount * blockDevice.blockSize

            guard let callbackHandle = withUnsafePointer(to: &coreCfg, { fs_core_device_from_callbacks($0) }) else {
                let err = fs_core_last_error_message().flatMap { String(cString: $0) } ?? "(no error set)"
                dlog.error("fs_core_device_from_callbacks failed: \(err)")
                Unmanaged<BlockDeviceContext>.fromOpaque(contextPtr).release()
                replyHandler(nil, POSIXError(.EIO))
                return
            }

            // Stack container reader on top of the callback handle.
            // Ownership transfers (container layer frees inner on NULL).
            var stackedHandle: OpaquePointer = callbackHandle
            if let kind = containerKind {
                guard let h = Self.openContainer(kind: kind, inner: stackedHandle, writable: isWritable) else {
                    let err = fs_core_last_error_message().flatMap { String(cString: $0) } ?? "(no error set)"
                    dlog.error("\(kind)_open\(isWritable ? "_rw" : "")_on_device failed: \(err)")
                    Unmanaged<BlockDeviceContext>.fromOpaque(contextPtr).release()
                    replyHandler(nil, POSIXError(.EIO))
                    return
                }
                stackedHandle = h
            }

            // Slice the (possibly container-wrapped) device when the
            // host requested a specific partition. The slice borrows
            // the parent's Arc, so closing the parent afterwards is
            // safe — the slice keeps it alive.
            var mountHandle: OpaquePointer = stackedHandle
            var preMountClose: [OpaquePointer] = []
            if let offset = partitionOffset, let length = partitionLength, offset > 0 || length > 0 {
                guard let s = (isWritable
                                ? fs_core_device_slice_rw(stackedHandle, offset, length)
                                : fs_core_device_slice_ro(stackedHandle, offset, length)) else {
                    let err = fs_core_last_error_message().flatMap { String(cString: $0) } ?? "(no error set)"
                    dlog.error("fs_core_device_slice_\(isWritable ? "rw" : "ro") failed: \(err)")
                    fs_core_device_close(stackedHandle)
                    Unmanaged<BlockDeviceContext>.fromOpaque(contextPtr).release()
                    replyHandler(nil, POSIXError(.EIO))
                    return
                }
                preMountClose.append(stackedHandle)  // stacked is now superseded; close after mount
                mountHandle = s
            }

            // fs_ext4_mount_with_fs_core_device_lazy clones an Arc<dyn
            // BlockDevice> from the handle, so closing our outer
            // handle afterwards is fine — the mount keeps its own
            // reference and the container layer + callbacks stay
            // alive until umount.
            dlog.info("calling fs_ext4_mount_with_fs_core_device\(isWritable ? "_lazy" : "")")
            bridgeFS = isWritable
                ? fs_ext4_mount_with_fs_core_device_lazy(mountHandle)
                : fs_ext4_mount_with_fs_core_device(mountHandle)
            fs_core_device_close(mountHandle)
            for h in preMountClose { fs_core_device_close(h) }
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
        Self.mountedResources.withLock { map in
            map[ObjectIdentifier(resource)] = MountedResource(
                bsdName: bsdName, backend: backend,
                contextPtr: contextPtr, opLock: OperationLock())
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
        Self.mountedResources.withLock { map in
            map.removeValue(forKey: ObjectIdentifier(resource))
        }
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
    }

    /// Probe the resource (offset 0 + trailing footer) for a known
    /// container magic. Returns nil when the bytes look like a raw
    /// partition image (or some unknown format that fs_ext4 can
    /// reject more cleanly than we can guess).
    static func detectContainer(context: BlockDeviceContext, sizeBytes: UInt64) -> ContainerKind? {
        // Offset 0 covers QCOW2, VHDX, VMDK, dynamic / differencing VHD.
        var head = [UInt8](repeating: 0, count: 16)
        let rc = head.withUnsafeMutableBufferPointer { buf -> Int32 in
            return context.read(into: buf.baseAddress!, offset: 0, length: 16)
        }
        if rc == 0 {
            // QCOW2: 51 46 49 fb
            if head[0] == 0x51 && head[1] == 0x46
                && head[2] == 0x49 && head[3] == 0xFB { return .qcow2 }
            // VHDX: "vhdxfile"
            let vhdx: [UInt8] = [0x76, 0x68, 0x64, 0x78, 0x66, 0x69, 0x6c, 0x65]
            if Array(head.prefix(8)) == vhdx { return .vhdx }
            // VMDK: "KDMV"
            let vmdk: [UInt8] = [0x4b, 0x44, 0x4d, 0x56]
            if Array(head.prefix(4)) == vmdk { return .vmdk }
            // Dynamic / differencing VHD: footer copy at offset 0
            let conectix: [UInt8] = [0x63, 0x6f, 0x6e, 0x65, 0x63, 0x74, 0x69, 0x78]
            if Array(head.prefix(8)) == conectix { return .vhd }
        }

        // Fixed VHD: footer-only at file_size - 512.
        if sizeBytes >= 512 {
            var footer = [UInt8](repeating: 0, count: 8)
            let frc = footer.withUnsafeMutableBufferPointer { buf -> Int32 in
                return context.read(into: buf.baseAddress!,
                                    offset: off_t(sizeBytes - 512),
                                    length: 8)
            }
            let conectix: [UInt8] = [0x63, 0x6f, 0x6e, 0x65, 0x63, 0x74, 0x69, 0x78]
            if frc == 0 && footer == conectix { return .vhd }
        }

        return nil
    }

    /// Construct the right `*_open*_on_device` call for the kind +
    /// writability. Consumes `inner` — on NULL return the called
    /// function has already freed it per the C ABI contract.
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
        Task.detached {
            defer { opLock.release() }
            let result = backend.runFsck(
                repair: repairRequested,
                onProgress: { phase, done, total in
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
        let resolved: MountedResource? = Self.mountedResources.withLock { map in
            guard !map.isEmpty else { return nil }
            // Same single-mount-per-extension assumption as startCheck —
            // surface ambiguity loudly rather than guessing.
            if map.count == 1 { return map.values.first }
            return nil
        }
        guard let resolved = resolved else {
            log.error(
                "startFormat: no loaded resource to format — disk must be probed/loaded first; see docs/fskit-format-pipeline.md",
                scope: AppLogScope.fsck
            )
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

        Task.detached {
            // Build a fresh blockdev cfg pointing at the same
            // BlockDeviceContext the live mount is using. The cfg's
            // read/write/flush callbacks dispatch through the same C
            // shim as the mount path — so writes go through FSKit's
            // FSBlockDeviceResource just like a normal file write
            // would. Safety caveat: if the volume is mounted, the
            // kernel buffer cache is now stale. Unmount-after-format
            // is the user's responsibility (see doc).
            let bdc = resolved.contextPtr
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
