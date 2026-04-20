/*
 * NTFSFileSystem.swift — FSKit filesystem module for NTFS.
 *
 * Mirrors the exact shape of DiskJockeyEXT4 (proven working on macOS 26):
 *   - probeResource + loadResource + unloadResource use the replyHandler
 *     callback style, not async/await. async/await fsmodule ops have
 *     been flaky on macOS 26; replyHandler is the reliable path.
 *   - loadResource MUST set `containerStatus = .ready` before returning
 *     the volume so fskitd stops holding the underlying FSBlockDeviceResource.
 *     Without this, the next operation on the device returns EAGAIN.
 *   - All reads go through a C callback wrapped around
 *     FSBlockDeviceResource (no direct /dev/diskN opens — sandbox-safe).
 */

import FSKit
import Foundation

/// Single logging surface — fans out to os_log + NDJSON file (tailed
/// by host app UI) via AppLog's configured sinks.
let log = AppLog(source: "ntfs", sinks: AppLog.defaultSinks(source: "ntfs"))

/// Wraps FSBlockDeviceResource for the C read callback. Handles block
/// alignment — FSBlockDeviceResource.read requires offset+length
/// aligned to blockSize, so we align + copy out the requested window.
final class NTFSBlockDeviceContext {
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
                log.error("bdev read short: off=\(offset) len=\(length) got=\(bytesRead)")
                return EIO
            }
            memcpy(buf, tmp.advanced(by: offsetDelta), length)
            return 0
        } catch {
            log.error("bdev read error: off=\(offset) len=\(length) err=\(error.localizedDescription)")
            return EIO
        }
    }

    /// Read-modify-write wrapper so sub-block writes (e.g. the 2-byte
    /// dirty-flag patch) work the same as aligned large writes (e.g. the
    /// $LogFile overwrite). FSBlockDeviceResource.write requires aligned
    /// offset+length, so we align, read the affected blocks, patch in the
    /// caller's bytes, and write the whole aligned window back.
    func write(from buf: UnsafeRawPointer, offset: off_t, length: Int) -> Int32 {
        let bs = max(blockSize, 512)
        let alignedOffset = (Int(offset) / bs) * bs
        let offsetDelta = Int(offset) - alignedOffset
        let alignedLength = ((offsetDelta + length + bs - 1) / bs) * bs

        let tmp = UnsafeMutableRawPointer.allocate(byteCount: alignedLength, alignment: bs)
        defer { tmp.deallocate() }

        do {
            // Only read-patch-write when the caller's window isn't
            // already block-aligned; otherwise skip the read entirely.
            if offsetDelta != 0 || alignedLength != length {
                let readRaw = UnsafeMutableRawBufferPointer(start: tmp, count: alignedLength)
                _ = try resource.read(into: readRaw, startingAt: off_t(alignedOffset), length: alignedLength)
            }
            memcpy(tmp.advanced(by: offsetDelta), buf, length)

            let writeRaw = UnsafeRawBufferPointer(start: tmp, count: alignedLength)
            try resource.write(from: writeRaw, startingAt: off_t(alignedOffset), length: alignedLength)
            return 0
        } catch {
            log.error("bdev write error: off=\(offset) len=\(length) err=\(error.localizedDescription)")
            return EIO
        }
    }
}

/// Context the C progress callback receives. Holds the correlation key
/// (BSD device name) so the host app can route fsck.progress events to
/// the right AttachedDisk.
final class FsckProgressContext {
    let bsdName: String
    init(bsdName: String) { self.bsdName = bsdName }
}

@objc(NTFSFileSystem)
final class NTFSFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    override init() {
        super.init()
    }

    // MARK: - Probe

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
            var buf = Data(count: 512)
            let bytesRead = try buf.withUnsafeMutableBytes { rawBuf in
                try blockDevice.read(into: rawBuf, startingAt: 0, length: 512)
            }

            guard bytesRead >= 12 else {
                log.info("probe: read \(bytesRead) bytes (< 12) — not NTFS")
                replyHandler(.notRecognized, nil)
                return
            }

            let oemID = String(bytes: buf[3..<11], encoding: .ascii) ?? ""
            guard oemID == "NTFS    " else {
                log.info("probe: OEM ID '\(oemID)' — not NTFS")
                replyHandler(.notRecognized, nil)
                return
            }

            let serial: UInt64 = buf.withUnsafeBytes { rawBuf in
                rawBuf.load(fromByteOffset: 0x48, as: UInt64.self)
            }
            log.info("probe: recognized NTFS volume (serial=0x\(String(serial, radix: 16)))")

            var uuidBytes = [UInt8](repeating: 0, count: 16)
            withUnsafeBytes(of: serial.bigEndian) { src in
                for i in 0..<8 { uuidBytes[i] = src[i] }
            }
            let containerID = FSContainerIdentifier(uuid: NSUUID(uuidBytes: uuidBytes) as UUID)

            // Retrieve the real volume label so macOS mounts us at
            // /Volumes/<label> instead of the generic "/Volumes/NTFS".
            // The label lives in MFT record #3 ($Volume) and can't be
            // read from the boot sector alone, so we do a brief read-
            // only mount via the callback ABI (no write callback —
            // fs_ntfs_mount is read-only), query volume info, then
            // unmount. Empty labels fall back to "NTFS".
            let probeContext = NTFSBlockDeviceContext(resource: blockDevice)
            let probeContextPtr = Unmanaged.passRetained(probeContext).toOpaque()
            defer { Unmanaged<NTFSBlockDeviceContext>.fromOpaque(probeContextPtr).release() }

            var probeCfg = fs_ntfs_blockdev_cfg_t()
            probeCfg.read = { ctx, buf, offset, length in
                guard let ctx = ctx, let buf = buf else { return EIO }
                let context = Unmanaged<NTFSBlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                return context.read(into: buf, offset: off_t(offset), length: Int(length))
            }
            probeCfg.context = probeContextPtr
            probeCfg.size_bytes = blockDevice.blockCount * blockDevice.blockSize

            var label = "NTFS"
            if let probeFS = fs_ntfs_mount_with_callbacks(&probeCfg) {
                var volInfo = fs_ntfs_volume_info_t()
                if fs_ntfs_get_volume_info(probeFS, &volInfo) == 0 {
                    let parsed = withUnsafePointer(to: volInfo.volume_name) { ptr in
                        ptr.withMemoryRebound(to: CChar.self, capacity: 128) { cstr in
                            String(cString: cstr)
                        }
                    }
                    if !parsed.isEmpty {
                        label = parsed
                    }
                }
                fs_ntfs_umount(probeFS)
            } else {
                let err = fs_ntfs_last_error().flatMap { String(cString: $0) } ?? "(no error)"
                log.warn("probe: volume label lookup failed — \(err); using fallback 'NTFS'")
            }

            log.info("probe: label=\"\(label)\"")
            replyHandler(.usable(name: label, containerID: containerID), nil)
        } catch {
            log.error("probe: block-device read failed — \(error.localizedDescription)")
            replyHandler(.notRecognized, nil)
        }
    }

    // MARK: - Load

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

        let context = NTFSBlockDeviceContext(resource: blockDevice)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        var cfg = fs_ntfs_blockdev_cfg_t()
        cfg.read = { ctx, buf, offset, length in
            guard let ctx = ctx, let buf = buf else { return EIO }
            let context = Unmanaged<NTFSBlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
            return context.read(into: buf, offset: off_t(offset), length: Int(length))
        }
        cfg.write = { ctx, buf, offset, length in
            guard let ctx = ctx, let buf = buf else { return EIO }
            let context = Unmanaged<NTFSBlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
            return context.write(from: buf, offset: off_t(offset), length: Int(length))
        }
        cfg.context = contextPtr
        cfg.size_bytes = blockDevice.blockCount * blockDevice.blockSize

        // Dirty-check + conditional fsck BEFORE mount. Upstream ntfs crate
        // (ColinFinck/ntfs) will happily parse a dirty volume read-only —
        // Windows would still insist on chkdsk next plug-in though, so
        // clear the dirty bit + reset $LogFile while we have the device.
        let bsdName = blockDevice.bsdName
        switch fs_ntfs_is_dirty_with_callbacks(&cfg) {
        case 1:
            log.event(kind: "volume.dirty", fields: ["bsd": bsdName])
            log.event(kind: "fsck.start", fields: ["bsd": bsdName])

            let progressCtx = FsckProgressContext(bsdName: bsdName)
            let progressCtxPtr = Unmanaged.passRetained(progressCtx).toOpaque()
            defer { Unmanaged<FsckProgressContext>.fromOpaque(progressCtxPtr).release() }

            var logfileBytes: UInt64 = 0
            var dirtyCleared: UInt8 = 0
            let rc = fs_ntfs_fsck_with_callbacks(
                &cfg,
                { ctx, phase, done, total in
                    guard let ctx = ctx, let phase = phase else { return 0 }
                    let pctx = Unmanaged<FsckProgressContext>.fromOpaque(ctx).takeUnretainedValue()
                    let phaseStr = String(cString: phase)
                    log.event(kind: "fsck.progress", fields: [
                        "bsd": pctx.bsdName,
                        "phase": phaseStr,
                        "done": "\(done)",
                        "total": "\(total)"
                    ])
                    return 0
                },
                progressCtxPtr,
                &logfileBytes,
                &dirtyCleared
            )

            if rc == 0 {
                log.event(kind: "fsck.done", fields: [
                    "bsd": bsdName,
                    "logfile_bytes": "\(logfileBytes)",
                    "dirty_cleared": dirtyCleared == 1 ? "true" : "false"
                ])
            } else {
                let err = fs_ntfs_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
                log.event(kind: "fsck.failed", fields: ["bsd": bsdName, "error": err], level: .error)
                // Fall through to mount attempt — the ntfs crate can still
                // read-only-parse a dirty volume; reads will work. Clean
                // shutdown will be incomplete though.
            }
        case 0:
            log.event(kind: "volume.clean", fields: ["bsd": bsdName])
        default:
            let err = fs_ntfs_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
            log.event(kind: "dirty.check.failed", fields: ["bsd": bsdName, "error": err], level: .warn)
        }

        log.info("calling fs_ntfs_mount_with_callbacks size=\(cfg.size_bytes) blockSize=\(blockDevice.blockSize)")

        guard let bridgeFS = fs_ntfs_mount_with_callbacks(&cfg) else {
            let err = fs_ntfs_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
            log.error("fs_ntfs mount failed: \(err)")
            Unmanaged<NTFSBlockDeviceContext>.fromOpaque(contextPtr).release()
            replyHandler(nil, POSIXError(.EIO))
            return
        }
        log.info("fs_ntfs mount succeeded")

        var volInfo = fs_ntfs_volume_info_t()
        fs_ntfs_get_volume_info(bridgeFS, &volInfo)
        let volumeName = withUnsafePointer(to: volInfo.volume_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 128) { cstr in
                String(cString: cstr)
            }
        }
        let resolvedName = volumeName.isEmpty ? "NTFS" : volumeName

        let volID = FSVolume.Identifier()
        let volume = NTFSVolume(
            volumeID: volID,
            volumeName: FSFileName(string: resolvedName),
            bridgeFS: bridgeFS,
            blockDevice: blockDevice
        )

        // CRITICAL: matches EXT4 pattern. Without this, fskitd never gets
        // the "load completed" signal and subsequent operations on the
        // resource fail with EAGAIN ("Resource temporarily unavailable").
        containerStatus = .ready
        log.info("volume ready: \"\(resolvedName)\"")
        // Emit one compact event with volume-identity + sizing so the host
        // app can populate the detail pane without re-parsing the text log.
        log.event(kind: "volume.info", fields: [
            "bsd": bsdName,
            "fs": "ntfs",
            "volume_name": resolvedName,
            "cluster_size": "\(volInfo.cluster_size)",
            "total_clusters": "\(volInfo.total_clusters)",
            "total_size": "\(volInfo.total_size)",
            "ntfs_version": "\(volInfo.ntfs_version_major).\(volInfo.ntfs_version_minor)",
            "serial_number": "0x\(String(volInfo.serial_number, radix: 16))",
        ])
        replyHandler(volume, nil)
    }

    // MARK: - Unload

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

// fskitd calls `_checkResource:` on every mount (not just explicit fsck)
// to decide whether to go down the check/repair path. Without this
// conformance the call returns ENOTSUP (POSIX 45) and the system
// refuses to mount. EXT4 has the same stub — keep them in sync.
extension NTFSFileSystem: FSManageableResourceMaintenanceOperations {
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
