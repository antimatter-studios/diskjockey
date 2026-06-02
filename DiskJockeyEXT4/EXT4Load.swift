/*
 * EXT4Load.swift — FSKit `loadResource` / `unloadResource` pipeline,
 * including the fs_core handle-chain construction (callbacks →
 * optional container reader → optional partition slice) and the
 * `volume.info` event the host app's AttachedDisksModel ingests.
 *
 * The two main entry points cover both resource kinds:
 *   • `loadResource(...)` for `FSBlockDeviceResource` (block-device
 *     path).
 *   • `loadFileResource(...)` for `FSPathURLResource` (file-backed
 *     path).
 *
 * They share `buildFsCoreHandle` / `openContainer` helpers, plus
 * `Self.detectContainer` / `Self.taskOption` / `Self.formatXxx`
 * which live in EXT4Probe.swift and EXT4FileSystem.swift respectively.
 */

import FSKit
import Foundation
import DiskJockeyLibrary

extension EXT4FileSystem {

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

    // MARK: - File resource (FSPathURLResource) load

    fileprivate func loadFileResource(
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

    // MARK: - fs_core handle chain construction

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
}
