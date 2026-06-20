/*
 * SquashfsFileSystem.swift — FSKit filesystem module for SquashFS (read-only).
 *
 * Mirrors the proven shape of DiskJockeyEXT4 / DiskJockeyNTFS on macOS 26:
 *   - probeResource / loadResource / unloadResource use the replyHandler
 *     callback style (async/await fsmodule ops have been flaky on macOS 26).
 *   - loadResource sets `containerStatus = .ready` before returning the
 *     volume so fskitd stops holding the FSBlockDeviceResource (otherwise
 *     the next op returns EAGAIN).
 *   - All reads go through a C callback wrapped around FSBlockDeviceResource
 *     (no direct /dev/diskN opens — sandbox-safe).
 *
 * SquashFS is READ-ONLY: there is no write/format path. The crate doesn't
 * pull in the am-img-* container readers, so this extension mounts raw
 * partitions and partition slices (via fs_core), but not disk-image
 * containers (qcow2/vhd/…) — that's an additive follow-up.
 */

import FSKit
import Foundation
import DiskJockeyLibrary

/// Single logging surface — fans out to os_log + NDJSON file via AppLog.
let log = AppLog(source: "squashfs", sinks: AppLog.defaultSinks(source: "squashfs"))

@objc(SquashfsFileSystem)
final class SquashfsFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    /// Registered per mount so `startCheck` (which FSKit invokes without a
    /// resource handle) can resolve the live volume. Mirror of the
    /// EXT4/NTFS registries; SquashFS needs only the protocol minimum
    /// (bsdName + opLock) plus the volume.
    struct MountedResource: DiskJockeyLibrary.MountedResource {
        let bsdName: String
        let volume: SquashfsVolume
        let opLock: OperationLock
    }
    static let mountedResources = MountedResourceRegistry<MountedResource>()

    // MARK: - Probe

    func probeResource(
        resource: FSResource,
        replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        log.info("probe called", scope: AppLogScope.probe)
        guard let blockDevice = resource as? FSBlockDeviceResource else {
            log.warn("probe: unsupported resource type — not recognized", scope: AppLogScope.probe)
            replyHandler(.notRecognized, nil)
            return
        }
        let dlog = TaggedLogger(
            log, fields: ["bsd": blockDevice.bsdName], kind: "squashfs.probe",
            scope: AppLogScope.probe
        )
        dlog.info("probe \(blockDevice.bsdName): blockSize=\(blockDevice.blockSize) blockCount=\(blockDevice.blockCount)")

        do {
            // The SquashFS superblock is 96 bytes at offset 0. We only need
            // the magic + a few fields to build a stable container id.
            var buf = Data(count: 96)
            let bytesRead = try buf.withUnsafeMutableBytes { rawBuf in
                try blockDevice.read(into: rawBuf, startingAt: 0, length: 96)
            }
            guard bytesRead >= 96 else {
                dlog.info("probe: read \(bytesRead) bytes (< 96) — not SquashFS")
                replyHandler(.notRecognized, nil)
                return
            }
            // "hsqs" little-endian magic at offset 0.
            guard buf[0] == 0x68, buf[1] == 0x73, buf[2] == 0x71, buf[3] == 0x73 else {
                dlog.info("probe: magic mismatch — not SquashFS")
                replyHandler(.notRecognized, nil)
                return
            }

            // SquashFS has no volume UUID. Synthesize a stable container id
            // from modification_time (off 8), inode_count (off 4), and
            // bytes_used (off 40) — together unique enough per image.
            var uuidBytes = [UInt8](repeating: 0, count: 16)
            for i in 0..<4 { uuidBytes[i] = buf[8 + i] }       // modification_time
            for i in 0..<4 { uuidBytes[4 + i] = buf[4 + i] }   // inode_count
            for i in 0..<8 { uuidBytes[8 + i] = buf[40 + i] }  // bytes_used
            let containerID = FSContainerIdentifier(uuid: NSUUID(uuidBytes: uuidBytes) as UUID)

            dlog.info("probe: recognized SquashFS image")
            replyHandler(.usable(name: "SquashFS", containerID: containerID), nil)
        } catch {
            dlog.error("probe: block-device read failed — \(error.localizedDescription)")
            replyHandler(.notRecognized, nil)
        }
    }

    // MARK: - Load

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
        let dlog = TaggedLogger(
            log, fields: ["bsd": bsdName], kind: "squashfs.load",
            scope: AppLogScope.lifecycle
        )
        dlog.info("loadResource \(bsdName): blockSize=\(blockDevice.blockSize) blockCount=\(blockDevice.blockCount) taskOptions=\(options.taskOptions)")

        let stats = IOStatsRecorder(label: bsdName, emit: { fields in
            dlog.event(kind: "io.stats", fields: fields, scope: AppLogScope.stats)
        })
        // Read-only context: no write strategy needed; an in-process read
        // cache absorbs the repeated metadata-block fetches the decompressor
        // makes. SquashFS reads aren't physical-block aligned.
        let context = BlockDeviceContext(
            resource: blockDevice,
            log: dlog,
            stats: stats,
            readCache: BlockReadCache(maxEntries: 512),
            alignToPhysicalBlockSize: false
        )
        let contextPtr = Unmanaged.passRetained(context).toOpaque()
        let cfgSizeBytes = blockDevice.blockCount * blockDevice.blockSize

        // Partition-aware mount: the host passes partition_offset=N /
        // partition_length=M when attaching a specific partition. We slice
        // the device at that range (via fs_core) and mount squashfs on the
        // slice. No container (qcow2/vhd) layer — see file header.
        let argv = options.taskOptions
        let partitionOffset = Self.taskOption("partition_offset", from: argv) { UInt64($0) }
        let partitionLength = Self.taskOption("partition_length", from: argv) { UInt64($0) }

        let bridgeFS: OpaquePointer?
        if partitionOffset != nil || partitionLength != nil {
            dlog.info("fs_core mount path: partition_offset=\(partitionOffset ?? 0) partition_length=\(partitionLength ?? 0)")
            do {
                let handle = try Self.buildFsCoreHandle(
                    contextPtr: contextPtr,
                    sizeBytes: cfgSizeBytes,
                    partitionOffset: partitionOffset,
                    partitionLength: partitionLength,
                    dlog: dlog
                )
                bridgeFS = fs_squashfs_mount_with_fs_core_device(handle)
                fs_core_device_close(handle)
            } catch {
                Unmanaged<BlockDeviceContext>.fromOpaque(contextPtr).release()
                replyHandler(nil, error)
                return
            }
        } else {
            var cfg = fs_squashfs_blockdev_cfg_t()
            cfg.read = { ctx, buf, offset, length in
                guard let ctx = ctx, let buf = buf else { return EIO }
                let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                return context.read(into: buf, offset: off_t(offset), length: Int(length))
            }
            cfg.context = contextPtr
            cfg.size_bytes = cfgSizeBytes
            dlog.info("calling fs_squashfs_mount_with_callbacks (ro) size=\(cfg.size_bytes)")
            bridgeFS = fs_squashfs_mount_with_callbacks(&cfg)
        }

        guard let bridgeFS = bridgeFS else {
            let err = fs_squashfs_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
            dlog.error("fs_squashfs mount failed (ro): \(err)")
            Unmanaged<BlockDeviceContext>.fromOpaque(contextPtr).release()
            replyHandler(nil, POSIXError(.EIO))
            return
        }

        var volInfo = fs_squashfs_volume_info_t()
        fs_squashfs_get_volume_info(bridgeFS, &volInfo)
        // SquashFS has no volume label — mount under a stable generic name.
        let resolvedName = "SquashFS"

        let volID = FSVolume.Identifier()
        let volume = SquashfsVolume(
            volumeID: volID,
            volumeName: FSFileName(string: resolvedName),
            bridgeFS: bridgeFS,
            blockDevice: blockDevice,
            contextPtr: contextPtr,
            bsdName: bsdName,
            stats: stats
        )
        Self.mountedResources.register(resource, MountedResource(
            bsdName: bsdName, volume: volume, opLock: OperationLock()))
        stats.start()

        // CRITICAL (matches EXT4/NTFS): without this, fskitd never gets the
        // "load completed" signal and subsequent ops fail with EAGAIN.
        containerStatus = .ready
        dlog.info("volume ready: \"\(resolvedName)\"")
        dlog.event(kind: "volume.info", fields: [
            "fs": "squashfs",
            "block_size": "\(volInfo.block_size)",
            "compression": withUnsafePointer(to: volInfo.compression_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
            },
            "inode_count": "\(volInfo.inode_count)",
            "bytes_used": "\(volInfo.bytes_used)",
        ], scope: AppLogScope.volume)
        replyHandler(volume, nil)
    }

    // MARK: - Unload

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        log.info("unloadResource called", scope: AppLogScope.lifecycle)
        Self.mountedResources.remove(resource)
        reply(nil)
    }

    func didFinishLoading() {}

    // MARK: - Helpers

    /// Parse a `key=value` mount option out of FSTaskOptions.taskOptions.
    static func taskOption<T>(_ name: String,
                              from argv: [String],
                              parser: (String) -> T?) -> T? {
        for raw in argv {
            for pair in raw.split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 && kv[0] == name, let v = parser(kv[1]) { return v }
            }
        }
        return nil
    }

    /// Build an FsCoreDevice chain: read callbacks → optional partition
    /// slice. The returned handle must be passed to a `fs_squashfs_mount_*`
    /// call and then closed with `fs_core_device_close`. Throws
    /// `POSIXError(.EIO)` on failure (caller releases contextPtr).
    static func buildFsCoreHandle(
        contextPtr: UnsafeMutableRawPointer,
        sizeBytes: UInt64,
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
        coreCfg.write = nil
        coreCfg.flush = nil
        coreCfg.ctx = contextPtr
        coreCfg.size = sizeBytes

        guard let handle = withUnsafePointer(to: &coreCfg, { fs_core_device_from_callbacks($0) }) else {
            let err = fs_core_last_error_message().flatMap { String(cString: $0) } ?? "(no error set)"
            dlog.error("fs_core_device_from_callbacks failed: \(err)")
            throw POSIXError(.EIO)
        }

        if let offset = partitionOffset, let length = partitionLength, offset > 0 || length > 0 {
            guard let slice = fs_core_device_slice_ro(handle, offset, length) else {
                let err = fs_core_last_error_message().flatMap { String(cString: $0) } ?? "(no error set)"
                dlog.error("fs_core_device_slice_ro failed: \(err)")
                fs_core_device_close(handle)
                throw POSIXError(.EIO)
            }
            fs_core_device_close(handle) // the slice keeps its own Arc
            return slice
        }
        return handle
    }
}

// fskitd calls `_checkResource:` on every mount to decide whether to go
// down the check/repair path. Without this conformance the call returns
// ENOTSUP and the system refuses to mount. SquashFS is read-only and
// immutable, so the check is a trivial always-clean success and format is
// unsupported.
extension SquashfsFileSystem: FSManageableResourceMaintenanceOperations {
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        log.info("startCheck: SquashFS is read-only/immutable — reporting clean", scope: AppLogScope.fsck)
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        task.didComplete(error: nil)
        return progress
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        log.error("startFormat: SquashFS is read-only — format not supported", scope: AppLogScope.fsck)
        throw POSIXError(.ENOTSUP)
    }
}

// MARK: - MountableFileSystem conformance
extension SquashfsFileSystem: MountableFileSystem {}
