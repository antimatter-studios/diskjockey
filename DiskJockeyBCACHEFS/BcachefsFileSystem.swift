/*
 * BcachefsFileSystem.swift — FSKit filesystem module for bcachefs.
 *
 * The proven shape of the sibling extensions on macOS 26:
 *   - probeResource / loadResource / unloadResource use replyHandler.
 *   - loadResource sets `containerStatus = .ready` before returning the
 *     volume, so fskitd stops holding the resource.
 *   - Every device read and write goes through FSBlockDeviceResource, by
 *     way of a BlockDeviceContext and fs_core callbacks (no /dev opens:
 *     the extension is sandboxed).
 *
 * Read-write by default: BcachefsMountPolicy decides, from the device and
 * the mount's options, and BcachefsDriver opens the driver's write handle
 * on the same fs_core device as its read handle. Raw partitions and
 * partition slices are mounted; disk-image containers (qcow2/vhd/…) are
 * not opened by this extension.
 *
 * MIT License — see LICENSE
 */

import FSKit
import Foundation
import DiskJockeyLibrary

@objc(BcachefsFileSystem)
final class BcachefsFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    struct MountedResource: DiskJockeyLibrary.MountedResource {
        let bsdName: String
        let volume: BcachefsVolume
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
            log, fields: ["bsd": blockDevice.bsdName], kind: "bcachefs.probe",
            scope: AppLogScope.probe
        )
        do {
            // FSBlockDeviceResource only accepts block-aligned reads: read
            // whole blocks from 0 through the end of the superblock's
            // fixed fields and look at them there.
            let blockSize = max(Int(blockDevice.blockSize), 1)
            let need = BcachefsSuperblock.probeLength
            let readLen = ((need + blockSize - 1) / blockSize) * blockSize
            var buf = [UInt8](repeating: 0, count: readLen)
            let bytesRead = try buf.withUnsafeMutableBytes { raw in
                try blockDevice.read(into: raw, startingAt: 0, length: readLen)
            }
            guard bytesRead >= need,
                  let sb = BcachefsSuperblock(device: Array(buf.prefix(bytesRead))) else {
                dlog.info("probe: no bcachefs superblock")
                replyHandler(.notRecognized, nil)
                return
            }
            let containerID = FSContainerIdentifier(uuid: sb.containerUUID)
            dlog.info("probe: recognized bcachefs \"\(sb.label)\"")
            replyHandler(.usable(name: sb.label.isEmpty ? "bcachefs" : sb.label,
                                 containerID: containerID), nil)
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
            log, fields: ["bsd": bsdName], kind: "bcachefs.load",
            scope: AppLogScope.lifecycle
        )
        let argv = options.taskOptions
        let policy = BcachefsMountPolicy(deviceIsWritable: blockDevice.isWritable, options: argv)
        let writable = policy == .readWrite
        dlog.info("loadResource \(bsdName): blockSize=\(blockDevice.blockSize) blockCount=\(blockDevice.blockCount) deviceWritable=\(blockDevice.isWritable) policy=\(policy) taskOptions=\(argv)")

        let stats = IOStatsRecorder(label: bsdName, emit: { fields in
            dlog.event(kind: "io.stats", fields: fields, scope: AppLogScope.stats)
        })
        // Immediate writes: the driver commits each call in place and
        // expects the bytes on the device when its write returns. The read
        // cache absorbs repeated node reads and is invalidated by writes.
        let context = BlockDeviceContext(
            resource: blockDevice,
            log: dlog,
            stats: stats,
            writeStrategy: .immediate,
            readCache: BlockReadCache(maxEntries: 512),
            alignToPhysicalBlockSize: true
        )
        let contextPtr = Unmanaged.passRetained(context).toOpaque()
        let release = { Unmanaged<BlockDeviceContext>.fromOpaque(contextPtr).release() }

        let device: OpaquePointer
        do {
            device = try Self.deviceHandle(
                contextPtr: contextPtr,
                sizeBytes: blockDevice.blockCount * blockDevice.blockSize,
                writable: writable,
                partitionOffset: Self.taskOption("partition_offset", from: argv) { UInt64($0) },
                partitionLength: Self.taskOption("partition_length", from: argv) { UInt64($0) },
                dlog: dlog)
        } catch {
            release()
            replyHandler(nil, error)
            return
        }

        let driver: BcachefsDriver
        do {
            driver = try BcachefsDriver(device: device, writable: writable)
        } catch {
            dlog.error("fs_bcachefs mount failed: \(BcachefsDriver.lastErrorMessage())")
            release()
            replyHandler(nil, error)
            return
        }
        if let refusal = driver.writeRefusal {
            // Mounted read-write all the same: each write answers this.
            dlog.event(kind: "volume.write_refused", fields: [
                "errno": "\(refusal)",
                "reason": BcachefsDriver.lastErrorMessage(),
            ], scope: AppLogScope.volume)
        }

        let label = driver.label()
        let resolvedName = label.isEmpty ? "bcachefs" : label
        let volume = BcachefsVolume(
            volumeID: FSVolume.Identifier(),
            volumeName: FSFileName(string: resolvedName),
            backend: driver,
            policy: policy,
            bsdName: bsdName,
            stats: stats,
            releaseDevice: release
        )
        Self.mountedResources.register(resource, MountedResource(
            bsdName: bsdName, volume: volume, opLock: OperationLock()))
        stats.start()

        containerStatus = .ready
        let info = driver.volumeInfo()
        dlog.info("volume ready: \"\(resolvedName)\" (\(volume.allowsWrites ? "read-write" : "read-only"))")
        dlog.event(kind: "volume.info", fields: [
            "fs": "bcachefs",
            "volume_name": resolvedName,
            "writable": volume.allowsWrites ? "true" : "false",
            "block_size": "\(info?.blockSize ?? 0)",
            "total_size": "\(info?.totalBytes ?? 0)",
            "free_size": "\(info?.freeBytes ?? 0)",
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
    static func taskOption<T>(_ name: String, from argv: [String],
                              parser: (String) -> T?) -> T? {
        for raw in argv {
            for pair in raw.split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 && kv[0] == name, let v = parser(kv[1]) { return v }
            }
        }
        return nil
    }

    /// An fs_core device over the context's callbacks, sliced to the
    /// partition when the host named one. Writable only for a read-write
    /// mount. The caller owns the returned handle.
    static func deviceHandle(
        contextPtr: UnsafeMutableRawPointer,
        sizeBytes: UInt64,
        writable: Bool,
        partitionOffset: UInt64?,
        partitionLength: UInt64?,
        dlog: TaggedLogger
    ) throws -> OpaquePointer {
        var cfg = FsCoreCallbackCfg()
        cfg.read = { ctx, offset, buf, len in
            guard let ctx, let buf else { return EIO }
            return Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                .read(into: UnsafeMutableRawPointer(buf), offset: off_t(offset), length: Int(len))
        }
        cfg.write = writable ? { ctx, offset, buf, len in
            guard let ctx, let buf else { return EIO }
            return Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                .write(from: UnsafeRawPointer(buf), offset: off_t(offset), length: Int(len))
        } : nil
        cfg.flush = { ctx in
            guard let ctx else { return EIO }
            return Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue().flush()
        }
        cfg.ctx = contextPtr
        cfg.size = sizeBytes
        guard let handle = withUnsafePointer(to: &cfg, { fs_core_device_from_callbacks($0) }) else {
            let err = fs_core_last_error_message().map { String(cString: $0) } ?? "(no error set)"
            dlog.error("fs_core_device_from_callbacks failed: \(err)")
            throw POSIXError(.EIO)
        }
        guard let offset = partitionOffset, let length = partitionLength,
              offset > 0 || length > 0 else {
            return handle
        }
        defer { fs_core_device_close(handle) } // the slice keeps its own reference
        guard let slice = writable
                ? fs_core_device_slice_rw(handle, offset, length)
                : fs_core_device_slice_ro(handle, offset, length) else {
            let err = fs_core_last_error_message().map { String(cString: $0) } ?? "(no error set)"
            dlog.error("fs_core_device_slice failed: \(err)")
            throw POSIXError(.EIO)
        }
        return slice
    }
}

// fskitd calls `_checkResource:` on every mount; without this conformance
// the call returns ENOTSUP and the system refuses to mount. The driver's
// checker has no C ABI entry point, so the check reports success without
// reading anything, as the XFS, EROFS and SquashFS extensions do; format is
// not supported.
extension BcachefsFileSystem: FSManageableResourceMaintenanceOperations {
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        log.info("startCheck: no checker in the driver's C ABI — reporting clean", scope: AppLogScope.fsck)
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        task.didComplete(error: nil)
        return progress
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        log.error("startFormat: formatting bcachefs is not supported", scope: AppLogScope.fsck)
        throw POSIXError(.ENOTSUP)
    }
}

// MARK: - MountableFileSystem conformance
extension BcachefsFileSystem: MountableFileSystem {}
