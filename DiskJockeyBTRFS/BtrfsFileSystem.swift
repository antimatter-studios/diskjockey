/*
 * BtrfsFileSystem.swift — FSKit filesystem module for BTRFS (read-only).
 *
 * Mirrors DiskJockeySQUASHFS (and the proven EXT4/NTFS shape on macOS 26):
 *   - probeResource / loadResource / unloadResource use replyHandler.
 *   - loadResource sets `containerStatus = .ready` before returning.
 *   - All reads go through a C callback over FSBlockDeviceResource.
 *
 * BTRFS is an inherently READ-ONLY filesystem: no write/format path.
 * am-fs-btrfs itself doesn't use the am-img-* container readers; the
 * dj-btrfs-bundle Cargo.toml links them only to prevent duplicate-symbol
 * linker errors (not to expose container-format mounting). This extension
 * therefore mounts raw partitions and partition slices (via fs_core), not
 * disk-image containers (qcow2/vhd/…).
 */

import FSKit
import Foundation
import DiskJockeyLibrary

@objc(BtrfsFileSystem)
final class BtrfsFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    struct MountedResource: DiskJockeyLibrary.MountedResource {
        let bsdName: String
        let volume: BtrfsVolume
        let opLock: OperationLock
    }
    static let mountedResources = MountedResourceRegistry<MountedResource>()

    // BTRFS superblock lives at byte offset 1024 and is 128 bytes long.
    // The primary Btrfs superblock lives at 64 KiB, not at the start of
    // the volume. Mirrors exist at 64 MiB and 256 GiB; the primary is
    // enough to recognise the filesystem.
    private static let superOffset: off_t = 65536
    private static let superSize = 4096

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
            log, fields: ["bsd": blockDevice.bsdName], kind: "btrfs.probe",
            scope: AppLogScope.probe
        )
        dlog.info("probe \(blockDevice.bsdName): blockSize=\(blockDevice.blockSize) blockCount=\(blockDevice.blockCount)")

        do {
            // FSBlockDeviceResource only accepts BLOCK-ALIGNED reads —
            // offset and length must both be multiples of blockSize. A
            // sub-block read returns EINVAL and fails the probe silently.
            // 65536 is aligned for any supported block size.
            let blockSize = max(Int(blockDevice.blockSize), 1)
            let readLen = ((Self.superSize + blockSize - 1) / blockSize) * blockSize
            var buf = Data(count: readLen)
            let bytesRead = try buf.withUnsafeMutableBytes { rawBuf in
                try blockDevice.read(into: rawBuf, startingAt: Self.superOffset, length: readLen)
            }
            guard bytesRead >= Self.superSize else {
                dlog.info("probe: read \(bytesRead) bytes (< \(Self.superSize)) — not Btrfs")
                replyHandler(.notRecognized, nil)
                return
            }
            // The magic is the ASCII string "_BHRfS_M" at offset 0x40
            // WITHIN the superblock — not at the start of it, and not at
            // the start of the volume.
            let magic: [UInt8] = Array("_BHRfS_M".utf8)
            guard Array(buf[0x40..<(0x40 + 8)]) == magic else {
                dlog.info("probe: magic mismatch — not Btrfs")
                replyHandler(.notRecognized, nil)
                return
            }

            // fsid is 16 bytes at superblock offset 0x20.
            var uuidBytes = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 { uuidBytes[i] = buf[0x20 + i] }
            let containerID = FSContainerIdentifier(uuid: NSUUID(uuidBytes: uuidBytes) as UUID)

            dlog.info("probe: recognized BTRFS image")
            replyHandler(.usable(name: "BTRFS", containerID: containerID), nil)
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
            log, fields: ["bsd": bsdName], kind: "btrfs.load",
            scope: AppLogScope.lifecycle
        )
        dlog.info("loadResource \(bsdName): blockSize=\(blockDevice.blockSize) blockCount=\(blockDevice.blockCount) taskOptions=\(options.taskOptions)")

        let stats = IOStatsRecorder(label: bsdName, emit: { fields in
            dlog.event(kind: "io.stats", fields: fields, scope: AppLogScope.stats)
        })
        let context = BlockDeviceContext(
            resource: blockDevice,
            log: dlog,
            stats: stats,
            readCache: BlockReadCache(maxEntries: 512),
            alignToPhysicalBlockSize: false
        )
        let contextPtr = Unmanaged.passRetained(context).toOpaque()
        let cfgSizeBytes = blockDevice.blockCount * blockDevice.blockSize

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
                bridgeFS = fs_btrfs_mount_with_fs_core_device(handle)
                fs_core_device_close(handle)
            } catch {
                Unmanaged<BlockDeviceContext>.fromOpaque(contextPtr).release()
                replyHandler(nil, error)
                return
            }
        } else {
            var cfg = fs_btrfs_blockdev_cfg_t()
            cfg.read = { ctx, buf, offset, length in
                guard let ctx = ctx, let buf = buf else { return EIO }
                let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                return context.read(into: buf, offset: off_t(offset), length: Int(length))
            }
            cfg.context = contextPtr
            cfg.size_bytes = cfgSizeBytes
            dlog.info("calling fs_btrfs_mount_with_callbacks (ro) size=\(cfg.size_bytes)")
            bridgeFS = fs_btrfs_mount_with_callbacks(&cfg)
        }

        guard let bridgeFS = bridgeFS else {
            let err = fs_btrfs_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
            dlog.error("fs_btrfs mount failed (ro): \(err)")
            Unmanaged<BlockDeviceContext>.fromOpaque(contextPtr).release()
            replyHandler(nil, POSIXError(.EIO))
            return
        }

        var volInfo = fs_btrfs_volume_info_t()
        fs_btrfs_get_volume_info(bridgeFS, &volInfo)
        // Btrfs calls it `label`, and allows up to 255 bytes rather than
        // the 16 an EROFS volume name gets.
        let volumeName = withUnsafePointer(to: volInfo.label) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        let resolvedName = volumeName.isEmpty ? "BTRFS" : volumeName

        let volID = FSVolume.Identifier()
        let volume = BtrfsVolume(
            volumeID: volID,
            volumeName: FSFileName(string: resolvedName),
            driver: BtrfsDriver(fs: bridgeFS),
            contextPtr: contextPtr,
            bsdName: bsdName,
            stats: stats
        )
        Self.mountedResources.register(resource, MountedResource(
            bsdName: bsdName, volume: volume, opLock: OperationLock()))
        stats.start()

        containerStatus = .ready
        dlog.info("volume ready: \"\(resolvedName)\"")
        dlog.event(kind: "volume.info", fields: [
            "fs": "btrfs",
            "volume_name": resolvedName,
            "sector_size": "\(volInfo.sector_size)",
            "node_size": "\(volInfo.node_size)",
            "total_bytes": "\(volInfo.total_bytes)",
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

// fskitd calls `_checkResource:` on every mount; without this conformance
// the call returns ENOTSUP and the system refuses to mount. BTRFS is
// read-only/immutable, so check is an always-clean success, format is
// unsupported.
extension BtrfsFileSystem: FSManageableResourceMaintenanceOperations {
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        log.info("startCheck: BTRFS is read-only/immutable — reporting clean", scope: AppLogScope.fsck)
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        task.didComplete(error: nil)
        return progress
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        log.error("startFormat: BTRFS is read-only — format not supported", scope: AppLogScope.fsck)
        throw POSIXError(.ENOTSUP)
    }
}

// MARK: - MountableFileSystem conformance
extension BtrfsFileSystem: MountableFileSystem {}
