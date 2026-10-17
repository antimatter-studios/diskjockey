/*
 * XfsFileSystem.swift — FSKit filesystem module for XFS (read-only).
 *
 * Mirrors DiskJockeySQUASHFS (and the proven EXT4/NTFS shape on macOS 26):
 *   - probeResource / loadResource / unloadResource use replyHandler.
 *   - loadResource sets `containerStatus = .ready` before returning.
 *   - Device reads, writes and flushes use bounded FSBlockDeviceResource callbacks.
 *
 * Volumes mount read-write whenever the hardware is writable, the mounted
 * driver can write, and the mount did not ask for ro or --rdonly
 * (diskjockey#343). Otherwise they mount read-only and mutations answer
 * EROFS. The published callback mount is read-only, so until the driver
 * offers a writable device mount every volume takes the read-only path.
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
        /// What a check task runs (#324): the volume's own driver.
        let checker: XfsCheckingDriver
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
        let policy = XfsMountPolicy(options: options.taskOptions)
        let context: XfsBlockDeviceContext
        do {
            let partition = try XfsBlockDeviceContext.partitionOptions(options.taskOptions)
            context = try XfsBlockDeviceContext(
                device: blockDevice,
                partitionOffset: partition.offset,
                partitionLength: partition.length,
                cache: BlockReadCache(maxEntries: 512),
                stats: stats,
                logger: dlog
            )
        } catch {
            replyHandler(nil, error)
            return
        }
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        // A writable mount is asked for whenever the policy and the
        // hardware allow one. The driver refuses it -- a v4 volume, a log
        // holding unapplied records -- by returning NULL, and that volume
        // is then mounted read-only: the driver cannot write it, which is
        // a read-only mount whose mutations answer EROFS, not a refused
        // one (diskjockey#343).
        let bridgeFS: OpaquePointer?
        do {
            let handle = try XfsBlockDeviceBridge.makeHandle(contextPtr: contextPtr, logger: dlog)
            var mounted: OpaquePointer?
            if policy.requestsWritableMount(deviceIsWritable: blockDevice.isWritable) {
                dlog.info("calling fs_xfs_mount_rw_with_fs_core_device size=\(context.sizeBytes)")
                mounted = fs_xfs_mount_rw_with_fs_core_device(handle)
                if mounted == nil {
                    let err = fs_xfs_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
                    dlog.info("the driver cannot mount this volume for writing (errno \(fs_xfs_last_errno()): \(err)); mounting it read-only")
                }
            }
            if mounted == nil {
                dlog.info("calling fs_xfs_mount_with_fs_core_device (ro) size=\(context.sizeBytes)")
                mounted = fs_xfs_mount_with_fs_core_device(handle)
            }
            bridgeFS = mounted
            fs_core_device_close(handle)
        } catch {
            Unmanaged<XfsBlockDeviceContext>.fromOpaque(contextPtr).release()
            replyHandler(nil, error)
            return
        }

        guard let bridgeFS = bridgeFS else {
            let code = POSIXErrorCode(rawValue: Int32(fs_xfs_last_errno())) ?? .EIO
            let err = fs_xfs_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
            dlog.error("fs_xfs mount failed (ro): \(err)")
            Unmanaged<XfsBlockDeviceContext>.fromOpaque(contextPtr).release()
            replyHandler(nil, POSIXError(code))
            return
        }

        let driver = XfsDriver(fs: bridgeFS)
        let mountAccess: XfsMountAccess
        do {
            mountAccess = try policy.authorize(
                deviceIsWritable: blockDevice.isWritable,
                mountedDriver: .success(driver.isWritable))
        } catch {
            // A refused mount is never retried with weaker options, and never
            // leaves a mounted driver holding callbacks into a released
            // Swift context.
            driver.unmount()
            stats.stop()
            Unmanaged<XfsBlockDeviceContext>.fromOpaque(contextPtr).release()
            dlog.error("mount policy refused: \(error.localizedDescription)")
            replyHandler(nil, error)
            return
        }

        dlog.info("mount access: \(mountAccess.allowsWrites ? "read-write" : "read-only") (policy \(policy), device writable \(blockDevice.isWritable), driver writable \(driver.isWritable))")

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
        let opLock = OperationLock()
        let volume = XfsVolume(
            volumeID: volID,
            volumeName: FSFileName(string: resolvedName),
            driver: driver,
            contextPtr: contextPtr,
            bsdName: bsdName,
            stats: stats,
            mountAccess: mountAccess,
            opLock: opLock
        )
        // The checker is the volume, which hands a check its current
        // driver: a repair mounts the device again (#324).
        Self.mountedResources.register(resource, MountedResource(
            bsdName: bsdName, volume: volume, opLock: opLock, checker: volume))
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

    /// Mount the device behind `contextPtr` again, for writing when
    /// `writable` asks and the driver allows it, read-only otherwise: the
    /// mount a repair leaves the volume with, as loadResource made the
    /// first (#324). nil when it cannot be mounted at all.
    static func mountDriver(contextPtr: UnsafeMutableRawPointer, writable: Bool,
                            dlog: TaggedLogger) -> XfsDriver? {
        guard let handle = try? XfsBlockDeviceBridge.makeHandle(contextPtr: contextPtr, logger: dlog) else {
            return nil
        }
        defer { fs_core_device_close(handle) }
        var mounted: OpaquePointer?
        if writable {
            mounted = fs_xfs_mount_rw_with_fs_core_device(handle)
            if mounted == nil {
                let err = fs_xfs_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
                dlog.info("after the repair the driver cannot mount this volume for writing (errno \(fs_xfs_last_errno()): \(err)); mounting it read-only")
            }
        }
        if mounted == nil {
            mounted = fs_xfs_mount_with_fs_core_device(handle)
        }
        return mounted.map { XfsDriver(fs: $0) }
    }

}

// fskitd calls `_checkResource:` on every mount; without this conformance
// the call returns ENOTSUP and the system refuses to mount. A check runs
// the driver's checker over the mounted volume and writes nothing; a
// repair (-y) runs the driver's repair over the device, with the mounted
// driver let go first and the device mounted again after. What the task
// reports is decided in XfsCheck.swift (#324). Format is unsupported.
extension XfsFileSystem: FSManageableResourceMaintenanceOperations {
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        guard let resolved = Self.mountedResources.resolveSingle() else {
            log.error("startCheck: no (or ambiguous) mounted resource registered — refusing", scope: AppLogScope.fsck)
            throw POSIXError(.EBADF)
        }
        let dlog = TaggedLogger(
            log, fields: ["bsd": resolved.bsdName], kind: "xfs.fsck",
            scope: AppLogScope.fsck
        )
        // -y asks for a repair, -q is the check the system runs while
        // mounting, anything else is a verify (FsckOperation).
        let argv = options.taskOptions
        let operation = FsckOperation(checkOptions: argv)
        let volume = resolved.volume
        if let refused = XfsCheck.refusal(for: operation, deviceIsWritable: volume.deviceIsWritable) {
            dlog.warn("startCheck refused: taskOptions=\(argv): \(refused.localizedDescription)")
            throw refused
        }
        let opLock = resolved.opLock
        if let busy = opLock.tryAcquire(operation) {
            dlog.warn("startCheck rejected: volume busy with \(busy.displayName)")
            throw POSIXError(.EBUSY)
        }
        dlog.info("startCheck: taskOptions=\(argv) operation=\(operation.rawValue)")
        let repairing = operation == .repair
        dlog.event(kind: "fsck.start", fields: ["repair": repairing ? "true" : "false"])

        // The checker reports no progress of its own: one unit, done when
        // it returns.
        let progress = Progress(totalUnitCount: 1)
        let checker = resolved.checker
        // The lock is released before the task reports, because FSKit goes
        // on to mount from there and a lock still held refuses the mount's
        // first operations (diskjockey#166).
        if repairing {
            // The repair writes the device: the volume lets its driver go,
            // the driver's repair runs over the device, and the volume is
            // mounted again as it was (#324). Every operation answers EBUSY
            // under the .repair lock meanwhile.
            Task.detached {
                let result = volume.repairDevice({ contextPtr in
                    do {
                        let handle = try XfsBlockDeviceBridge.makeHandle(contextPtr: contextPtr, logger: dlog)
                        defer { fs_core_device_close(handle) }
                        // FSKit cancels the task through the Progress it
                        // was handed; the driver's repair asks after each
                        // item and stops before it writes.
                        return XfsCheck.runRepair(XfsDeviceRepair(handle: handle),
                                                  isCancelled: { progress.isCancelled },
                                                  onItem: { dlog.warn("repair \($0.logLine)") })
                    } catch {
                        return .failure(error as NSError)
                    }
                }, remount: { contextPtr, writable in
                    Self.mountDriver(contextPtr: contextPtr, writable: writable, dlog: dlog)
                })
                let outcome: (any Error)?
                switch result {
                case .success(let report):
                    dlog.event(kind: "fsck.done", fields: XfsCheck.repairEventFields(report))
                    progress.completedUnitCount = 1
                    outcome = nil
                case .failure(let error):
                    dlog.event(kind: "fsck.failed", fields: ["error": error.localizedDescription])
                    outcome = error
                }
                opLock.finish {
                    task.didComplete(error: outcome)
                }
            }
            return progress
        }
        Task.detached {
            let outcome: (any Error)?
            switch XfsCheck.run(checker, onFinding: { dlog.warn("fsck finding: \($0.logLine)") }) {
            case .success(let report):
                dlog.event(kind: "fsck.done", fields: XfsCheck.eventFields(report))
                progress.completedUnitCount = 1
                outcome = nil
            case .failure(let error):
                dlog.event(kind: "fsck.failed", fields: ["error": error.localizedDescription])
                outcome = error
            }
            opLock.finish {
                task.didComplete(error: outcome)
            }
        }
        return progress
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        log.error("startFormat: XFS is read-only — format not supported", scope: AppLogScope.fsck)
        throw POSIXError(.ENOTSUP)
    }
}

// MARK: - MountableFileSystem conformance
extension XfsFileSystem: MountableFileSystem {}
