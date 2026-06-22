/*
 * ErofsFileSystem.swift — FSKit filesystem module for EROFS (read-only).
 *
 * Mirrors DiskJockeySQUASHFS (and the proven EXT4/NTFS shape on macOS 26):
 *   - probeResource / loadResource / unloadResource use replyHandler.
 *   - loadResource sets `containerStatus = .ready` before returning.
 *   - All reads go through a C callback over FSBlockDeviceResource.
 *
 * EROFS is an inherently READ-ONLY filesystem: no write/format path.
 * am-fs-erofs itself doesn't use the am-img-* container readers; the
 * dj-erofs-bundle Cargo.toml links them only to prevent duplicate-symbol
 * linker errors (not to expose container-format mounting). This extension
 * therefore mounts raw partitions and partition slices (via fs_core), not
 * disk-image containers (qcow2/vhd/…).
 */

import FSKit
import Foundation
import DiskJockeyLibrary

/// Single logging surface — fans out to os_log + NDJSON file via AppLog.
let log = AppLog(source: "erofs", sinks: AppLog.defaultSinks(source: "erofs"))

@objc(ErofsFileSystem)
final class ErofsFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    struct MountedResource: DiskJockeyLibrary.MountedResource {
        let bsdName: String
        let volume: ErofsVolume
        let opLock: OperationLock
    }
    static let mountedResources = MountedResourceRegistry<MountedResource>()

    // EROFS superblock lives at byte offset 1024 and is 128 bytes long.
    private static let superOffset: off_t = 1024
    private static let superSize = 128

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
            log, fields: ["bsd": blockDevice.bsdName], kind: "erofs.probe",
            scope: AppLogScope.probe
        )
        dlog.info("probe \(blockDevice.bsdName): blockSize=\(blockDevice.blockSize) blockCount=\(blockDevice.blockCount)")

        do {
            // The EROFS superblock (incl. magic + uuid) sits at offset 1024.
            // FSBlockDeviceResource only accepts BLOCK-ALIGNED reads — offset
            // and length must both be multiples of blockSize. A sub-block
            // 128-byte read returns EINVAL ("Invalid argument"), which silently
            // failed the probe and is why EROFS volumes never mounted.
            // superOffset (1024) is block-aligned for 512-byte blocks; round
            // the length up to a whole block and slice the superblock back out.
            let blockSize = max(Int(blockDevice.blockSize), 1)
            let readLen = ((Self.superSize + blockSize - 1) / blockSize) * blockSize
            var buf = Data(count: readLen)
            let bytesRead = try buf.withUnsafeMutableBytes { rawBuf in
                try blockDevice.read(into: rawBuf, startingAt: Self.superOffset, length: readLen)
            }
            guard bytesRead >= Self.superSize else {
                dlog.info("probe: read \(bytesRead) bytes (< 128) — not EROFS")
                replyHandler(.notRecognized, nil)
                return
            }
            // EROFS_SUPER_MAGIC_V1 = 0xE0F5E1E2, little-endian at SB offset 0.
            guard buf[0] == 0xE2, buf[1] == 0xE1, buf[2] == 0xF5, buf[3] == 0xE0 else {
                dlog.info("probe: magic mismatch — not EROFS")
                replyHandler(.notRecognized, nil)
                return
            }

            // EROFS carries a 16-byte UUID at superblock offset 0x30.
            var uuidBytes = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 { uuidBytes[i] = buf[0x30 + i] }
            // Fall back to build_time (off 0x18) + blocks (off 0x24) when the
            // image has a zero UUID, so the container id stays stable + unique.
            if uuidBytes.allSatisfy({ $0 == 0 }) {
                for i in 0..<8 { uuidBytes[i] = buf[0x18 + i] }   // build_time
                for i in 0..<4 { uuidBytes[8 + i] = buf[0x24 + i] } // blocks
            }
            let containerID = FSContainerIdentifier(uuid: NSUUID(uuidBytes: uuidBytes) as UUID)

            dlog.info("probe: recognized EROFS image")
            replyHandler(.usable(name: "EROFS", containerID: containerID), nil)
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
            log, fields: ["bsd": bsdName], kind: "erofs.load",
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
                bridgeFS = fs_erofs_mount_with_fs_core_device(handle)
                fs_core_device_close(handle)
            } catch {
                Unmanaged<BlockDeviceContext>.fromOpaque(contextPtr).release()
                replyHandler(nil, error)
                return
            }
        } else {
            var cfg = fs_erofs_blockdev_cfg_t()
            cfg.read = { ctx, buf, offset, length in
                guard let ctx = ctx, let buf = buf else { return EIO }
                let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                return context.read(into: buf, offset: off_t(offset), length: Int(length))
            }
            cfg.context = contextPtr
            cfg.size_bytes = cfgSizeBytes
            dlog.info("calling fs_erofs_mount_with_callbacks (ro) size=\(cfg.size_bytes)")
            bridgeFS = fs_erofs_mount_with_callbacks(&cfg)
        }

        guard let bridgeFS = bridgeFS else {
            let err = fs_erofs_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
            dlog.error("fs_erofs mount failed (ro): \(err)")
            Unmanaged<BlockDeviceContext>.fromOpaque(contextPtr).release()
            replyHandler(nil, POSIXError(.EIO))
            return
        }

        var volInfo = fs_erofs_volume_info_t()
        fs_erofs_get_volume_info(bridgeFS, &volInfo)
        let volumeName = withUnsafePointer(to: volInfo.volume_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        let resolvedName = volumeName.isEmpty ? "EROFS" : volumeName

        let volID = FSVolume.Identifier()
        let volume = ErofsVolume(
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

        containerStatus = .ready
        dlog.info("volume ready: \"\(resolvedName)\"")
        dlog.event(kind: "volume.info", fields: [
            "fs": "erofs",
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
// the call returns ENOTSUP and the system refuses to mount. EROFS is
// read-only/immutable, so check is an always-clean success, format is
// unsupported.
extension ErofsFileSystem: FSManageableResourceMaintenanceOperations {
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        log.info("startCheck: EROFS is read-only/immutable — reporting clean", scope: AppLogScope.fsck)
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        task.didComplete(error: nil)
        return progress
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        log.error("startFormat: EROFS is read-only — format not supported", scope: AppLogScope.fsck)
        throw POSIXError(.ENOTSUP)
    }
}

// MARK: - MountableFileSystem conformance
extension ErofsFileSystem: MountableFileSystem {}
