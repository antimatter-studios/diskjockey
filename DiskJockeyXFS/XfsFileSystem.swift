/*
 * XfsFileSystem.swift — FSKit filesystem module for XFS (read-only).
 *
 * Mirrors DiskJockeySQUASHFS (and the proven EXT4/NTFS shape on macOS 26):
 *   - probeResource / loadResource / unloadResource use replyHandler.
 *   - loadResource sets `containerStatus = .ready` before returning.
 *   - All reads go through a C callback over FSBlockDeviceResource.
 *
 * XFS is an inherently READ-ONLY filesystem: no write/format path.
 * am-fs-xfs itself doesn't use the am-img-* container readers; the
 * dj-xfs-bundle Cargo.toml links them only to prevent duplicate-symbol
 * linker errors (not to expose container-format mounting). This extension
 * therefore mounts raw partitions and partition slices (via fs_core), not
 * disk-image containers (qcow2/vhd/…).
 */

import FSKit
import Foundation
import DiskJockeyLibrary

@objc(XfsFileSystem)
final class XfsFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    struct MountedResource: DiskJockeyLibrary.MountedResource {
        let bsdName: String
        let volume: XfsVolume
        let opLock: OperationLock
    }
    static let mountedResources = MountedResourceRegistry<MountedResource>()

    // XFS superblock lives at byte offset 1024 and is 128 bytes long.
    // The XFS superblock is the first structure on the volume, at byte
    // offset 0, and is 264 bytes long.
    private static let superOffset: off_t = 0
    private static let superSize = 264

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
            log, fields: ["bsd": blockDevice.bsdName], kind: "xfs.probe",
            scope: AppLogScope.probe
        )
        dlog.info("probe \(blockDevice.bsdName): blockSize=\(blockDevice.blockSize) blockCount=\(blockDevice.blockCount)")

        do {
            // FSBlockDeviceResource only accepts BLOCK-ALIGNED reads —
            // offset and length must both be multiples of blockSize. A
            // sub-block read returns EINVAL, which fails the probe
            // silently. Offset 0 is aligned for any block size; round the
            // length up to a whole block and slice the superblock out.
            let blockSize = max(Int(blockDevice.blockSize), 1)
            let readLen = ((Self.superSize + blockSize - 1) / blockSize) * blockSize
            var buf = Data(count: readLen)
            let bytesRead = try buf.withUnsafeMutableBytes { rawBuf in
                try blockDevice.read(into: rawBuf, startingAt: Self.superOffset, length: readLen)
            }
            guard bytesRead >= Self.superSize else {
                dlog.info("probe: read \(bytesRead) bytes (< \(Self.superSize)) — not XFS")
                replyHandler(.notRecognized, nil)
                return
            }
            // sb_magicnum is the ASCII bytes X F S B, stored BIG-endian at
            // superblock offset 0. XFS is big-endian throughout, unlike
            // every sibling driver here — reading this little-endian is a
            // mistake this project has already made once.
            guard buf[0] == 0x58, buf[1] == 0x46, buf[2] == 0x53, buf[3] == 0x42 else {
                dlog.info("probe: magic mismatch — not XFS")
                replyHandler(.notRecognized, nil)
                return
            }

            // sb_uuid is 16 bytes at superblock offset 0x20. mkfs.xfs
            // always writes one, so unlike EROFS there is no zero-UUID
            // fallback to synthesise.
            var uuidBytes = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 { uuidBytes[i] = buf[0x20 + i] }
            let containerID = FSContainerIdentifier(uuid: NSUUID(uuidBytes: uuidBytes) as UUID)

            dlog.info("probe: recognized XFS image")
            replyHandler(.usable(name: "XFS", containerID: containerID), nil)
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
            log, fields: ["bsd": bsdName], kind: "xfs.load",
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
                bridgeFS = fs_xfs_mount_with_fs_core_device(handle)
                fs_core_device_close(handle)
            } catch {
                Unmanaged<BlockDeviceContext>.fromOpaque(contextPtr).release()
                replyHandler(nil, error)
                return
            }
        } else {
            var cfg = fs_xfs_blockdev_cfg_t()
            cfg.read = { ctx, buf, offset, length in
                guard let ctx = ctx, let buf = buf else { return EIO }
                let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                return context.read(into: buf, offset: off_t(offset), length: Int(length))
            }
            cfg.context = contextPtr
            cfg.size_bytes = cfgSizeBytes
            dlog.info("calling fs_xfs_mount_with_callbacks (ro) size=\(cfg.size_bytes)")
            bridgeFS = fs_xfs_mount_with_callbacks(&cfg)
        }

        guard let bridgeFS = bridgeFS else {
            let err = fs_xfs_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
            dlog.error("fs_xfs mount failed (ro): \(err)")
            Unmanaged<BlockDeviceContext>.fromOpaque(contextPtr).release()
            replyHandler(nil, POSIXError(.EIO))
            return
        }

        var volInfo = fs_xfs_volume_info_t()
        fs_xfs_get_volume_info(bridgeFS, &volInfo)
        // sb_fname is 12 bytes on disk; the ABI struct carries 13 so
        // there is always room for the terminator. Reading 16 here would
        // run past the end of the field.
        let volumeName = withUnsafePointer(to: volInfo.volume_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: volInfo.volume_name)) { String(cString: $0) }
        }
        let resolvedName = volumeName.isEmpty ? "XFS" : volumeName

        let volID = FSVolume.Identifier()
        let volume = XfsVolume(
            volumeID: volID,
            volumeName: FSFileName(string: resolvedName),
            driver: XfsDriver(fs: bridgeFS),
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
            "fs": "xfs",
            "volume_name": resolvedName,
            "block_size": "\(volInfo.block_size)",
            "inode_count": "\(volInfo.inode_count)",
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
// the call returns ENOTSUP and the system refuses to mount. XFS is
// read-only/immutable, so check is an always-clean success, format is
// unsupported.
extension XfsFileSystem: FSManageableResourceMaintenanceOperations {
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        log.info("startCheck: XFS is read-only/immutable — reporting clean", scope: AppLogScope.fsck)
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        task.didComplete(error: nil)
        return progress
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        log.error("startFormat: XFS is read-only — format not supported", scope: AppLogScope.fsck)
        throw POSIXError(.ENOTSUP)
    }
}

// MARK: - MountableFileSystem conformance
extension XfsFileSystem: MountableFileSystem {}
