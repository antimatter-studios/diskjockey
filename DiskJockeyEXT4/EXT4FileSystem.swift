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
final class BlockDeviceContext {
    let resource: FSBlockDeviceResource
    let blockSize: Int
    init(resource: FSBlockDeviceResource) {
        self.resource = resource
        self.blockSize = Int(resource.blockSize)
    }

    func read(into buf: UnsafeMutableRawPointer, offset: off_t, length: Int) -> Int32 {
        let bs = max(blockSize, 512)
        let alignedOffset = (Int(offset) / bs) * bs
        let offsetDelta = Int(offset) - alignedOffset
        let alignedLength = ((offsetDelta + length + bs - 1) / bs) * bs

        let tmp = UnsafeMutableRawPointer.allocate(byteCount: alignedLength, alignment: bs)
        defer { tmp.deallocate() }

        do {
            let rawBuf = UnsafeMutableRawBufferPointer(start: tmp, count: alignedLength)
            let bytesRead = try resource.read(into: rawBuf, startingAt: off_t(alignedOffset), length: alignedLength)
            if bytesRead < offsetDelta + length {
                log.error("bdev read short: off=\(offset) len=\(length) alignedOff=\(alignedOffset) alignedLen=\(alignedLength) got=\(bytesRead)")
                return EIO
            }
            memcpy(buf, tmp.advanced(by: offsetDelta), length)
            return 0
        } catch {
            log.error("bdev read error: off=\(offset) len=\(length) err=\(error.localizedDescription)")
            return EIO
        }
    }
}

@objc(EXT4FileSystem)
final class EXT4FileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    override init() {
        super.init()
    }


    func probeResource(
        resource: FSResource,
        replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        log.info("probe called")
        guard let blockDevice = resource as? FSBlockDeviceResource else {
            log.warn("probe: resource is not a block device — not recognized")
            replyHandler(.notRecognized, nil)
            return
        }
        log.info("probe \(blockDevice.bsdName): blockSize=\(blockDevice.blockSize) blockCount=\(blockDevice.blockCount)")

        do {
            var buf = [UInt8](repeating: 0, count: 1024)
            let bytesRead = try buf.withUnsafeMutableBytes { rawBuf in
                try blockDevice.read(into: rawBuf, startingAt: 1024, length: 1024)
            }

            guard bytesRead >= 58 else {
                log.info("probe: read \(bytesRead) bytes (< 58) — not ext4")
                replyHandler(.notRecognized, nil)
                return
            }

            let magic = UInt16(buf[56]) | (UInt16(buf[57]) << 8)
            guard magic == 0xEF53 else {
                log.info("probe: superblock magic mismatch (0x\(String(magic, radix: 16))) — not ext4")
                replyHandler(.notRecognized, nil)
                return
            }

            let nameBytes = buf[120..<136]
            let volumeName = String(bytes: nameBytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "ext4"
            let uuidBytes = Array(buf[104..<120])
            let containerID = FSContainerIdentifier(uuid: NSUUID(uuidBytes: uuidBytes) as UUID)
            log.info("probe: recognized ext4 volume \"\(volumeName)\"")

            replyHandler(.usable(name: volumeName, containerID: containerID), nil)
        } catch {
            log.error("probe: block-device read failed — \(error.localizedDescription)")
            replyHandler(.notRecognized, nil)
        }
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        log.info("loadResource called")
        guard let blockDevice = resource as? FSBlockDeviceResource else {
            log.error("loadResource: resource is not a block device — EINVAL")
            replyHandler(nil, POSIXError(.EINVAL))
            return
        }
        log.info("loadResource \(blockDevice.bsdName): blockSize=\(blockDevice.blockSize) blockCount=\(blockDevice.blockCount)")

        // Peek the superblock's s_state field to emit a clean/dirty
        // signal for the UI. Unlike NTFS, ext4 journal replay happens
        // automatically inside fs_ext4_mount_with_callbacks, so we
        // don't need a separate fsck pass — just visibility.
        // Superblock starts at byte 1024; s_state is u16 LE at offset
        // 0x3A. EXT4_VALID_FS=1 means cleanly unmounted.
        let bsdName = blockDevice.bsdName
        do {
            var sbBuf = [UInt8](repeating: 0, count: 1024)
            let bytesRead = try sbBuf.withUnsafeMutableBytes { rb in
                try blockDevice.read(into: rb, startingAt: 1024, length: 1024)
            }
            if bytesRead >= 0x3C {
                let state = UInt16(sbBuf[0x3A]) | (UInt16(sbBuf[0x3B]) << 8)
                let clean = state == 1   // EXT4_VALID_FS
                log.event(kind: clean ? "volume.clean" : "volume.dirty",
                          fields: ["bsd": bsdName, "s_state": "0x\(String(state, radix: 16))"])
            }
        } catch {
            log.event(kind: "dirty.check.failed",
                      fields: ["bsd": bsdName, "error": error.localizedDescription],
                      level: .warn)
        }

        let context = BlockDeviceContext(resource: blockDevice)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        var cfg = fs_ext4_blockdev_cfg_t()
        cfg.read = { ctx, buf, offset, length in
            guard let ctx = ctx, let buf = buf else { return EIO }
            let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
            return context.read(into: buf, offset: off_t(offset), length: Int(length))
        }
        cfg.context = contextPtr
        cfg.size_bytes = blockDevice.blockCount * blockDevice.blockSize
        cfg.block_size = UInt32(blockDevice.blockSize)
        log.info("calling fs_ext4_mount_with_callbacks size=\(cfg.size_bytes) blocksize=\(cfg.block_size)")

        guard let bridgeFS = fs_ext4_mount_with_callbacks(&cfg) else {
            let err = fs_ext4_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
            log.error("mount failed in fs_ext4: \(err)")
            Unmanaged<BlockDeviceContext>.fromOpaque(contextPtr).release()
            replyHandler(nil, POSIXError(.EIO))
            return
        }
        log.info("fs_ext4 mount succeeded")

        let backend = EXT4Backend(bridgeFS: bridgeFS)
        let volInfo = backend.volumeInfo()
        let volID = FSVolume.Identifier()
        let volume = EXT4Volume(
            volumeID: volID,
            volumeName: FSFileName(string: volInfo.name),
            backend: backend,
            blockDeviceContext: contextPtr
        )

        containerStatus = .ready
        log.info("volume ready: \"\(volInfo.name)\" blocks=\(volInfo.totalBlocks) free=\(volInfo.freeBlocks)")
        replyHandler(volume, nil)
    }

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        log.info("unloadResource called")
        reply(nil)
    }

    func didFinishLoading() {
    }
}

extension EXT4FileSystem: FSManageableResourceMaintenanceOperations {
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        let progress = Progress(totalUnitCount: 100)
        Task {
            progress.completedUnitCount = 100
            task.didComplete(error: nil)
        }
        return progress
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        throw POSIXError(.ENOSYS)
    }
}
