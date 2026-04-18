/*
 * EXT4FileSystem.swift — FSKit filesystem module for ext4.
 * Pattern matched from KhaosT/FSKitSample (macOS 26 compatible).
 */

import FSKit
import Foundation
import os

let logger = Logger(subsystem: "com.antimatterstudios.diskjockey.ext4", category: "filesystem")

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
                logger.error("bdev read short: reqOff=\(offset) reqLen=\(length) alignedOff=\(alignedOffset) alignedLen=\(alignedLength) got=\(bytesRead)")
                return EIO
            }
            memcpy(buf, tmp.advanced(by: offsetDelta), length)
            return 0
        } catch {
            logger.error("bdev read error: reqOff=\(offset) reqLen=\(length) alignedOff=\(alignedOffset) alignedLen=\(alignedLength) err=\(error.localizedDescription, privacy: .public)")
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
        logger.info("probeResource called")
        guard let blockDevice = resource as? FSBlockDeviceResource else {
            logger.info("probeResource: resource is not FSBlockDeviceResource")
            replyHandler(.notRecognized, nil)
            return
        }
        logger.info("probeResource: bsdName=\(blockDevice.bsdName, privacy: .public) blockSize=\(blockDevice.blockSize) blockCount=\(blockDevice.blockCount)")

        do {
            var buf = [UInt8](repeating: 0, count: 1024)
            let bytesRead = try buf.withUnsafeMutableBytes { rawBuf in
                try blockDevice.read(into: rawBuf, startingAt: 1024, length: 1024)
            }
            logger.info("probeResource: read \(bytesRead) bytes from offset 1024")

            guard bytesRead >= 58 else {
                logger.info("probeResource: bytesRead < 58, not recognized")
                replyHandler(.notRecognized, nil)
                return
            }

            let magic = UInt16(buf[56]) | (UInt16(buf[57]) << 8)
            logger.info("probeResource: magic=0x\(String(magic, radix: 16))")
            guard magic == 0xEF53 else {
                logger.info("probeResource: magic mismatch, not recognized")
                replyHandler(.notRecognized, nil)
                return
            }

            let nameBytes = buf[120..<136]
            let volumeName = String(bytes: nameBytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "ext4"
            let uuidBytes = Array(buf[104..<120])
            let containerID = FSContainerIdentifier(uuid: NSUUID(uuidBytes: uuidBytes) as UUID)
            logger.info("probeResource: returning usable name=\(volumeName, privacy: .public)")

            replyHandler(.usable(name: volumeName, containerID: containerID), nil)
        } catch {
            logger.error("probeResource: read error \(error.localizedDescription, privacy: .public)")
            replyHandler(.notRecognized, nil)
        }
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        logger.info("loadResource called")
        guard let blockDevice = resource as? FSBlockDeviceResource else {
            logger.error("loadResource: resource is not FSBlockDeviceResource")
            replyHandler(nil, POSIXError(.EINVAL))
            return
        }
        logger.info("loadResource: bsdName=\(blockDevice.bsdName, privacy: .public) blockSize=\(blockDevice.blockSize) blockCount=\(blockDevice.blockCount)")

        let context = BlockDeviceContext(resource: blockDevice)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        var cfg = ext4rs_blockdev_cfg_t()
        cfg.read = { ctx, buf, offset, length in
            guard let ctx = ctx, let buf = buf else { return EIO }
            let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
            return context.read(into: buf, offset: off_t(offset), length: Int(length))
        }
        cfg.context = contextPtr
        cfg.size_bytes = blockDevice.blockCount * blockDevice.blockSize
        cfg.block_size = UInt32(blockDevice.blockSize)
        logger.info("loadResource: calling ext4rs_mount_with_callbacks size=\(cfg.size_bytes) blocksize=\(cfg.block_size)")

        guard let bridgeFS = ext4rs_mount_with_callbacks(&cfg) else {
            let err = ext4rs_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
            logger.error("loadResource: ext4rs_mount_with_callbacks returned nil — \(err, privacy: .public)")
            Unmanaged<BlockDeviceContext>.fromOpaque(contextPtr).release()
            replyHandler(nil, POSIXError(.EIO))
            return
        }
        logger.info("loadResource: bridge mount succeeded")

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
        logger.info("loadResource: returning volume name=\(volInfo.name, privacy: .public)")
        replyHandler(volume, nil)
    }

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
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
