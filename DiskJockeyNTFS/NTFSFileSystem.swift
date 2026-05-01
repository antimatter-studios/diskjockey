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

/// Wraps FSBlockDeviceResource for the C read + write callbacks.
/// Handles block alignment — FSBlockDeviceResource requires aligned
/// offset+length, so we align + copy out the requested window (for
/// reads) or read-modify-write an aligned window (for sub-block
/// writes).
///
/// The `log` property is a subject-tagged logger (carrying
/// `fields["bsd"]=<disk>`) injected at construction time. The
/// `@convention(c)` closures wired into `fs_ntfs_blockdev_cfg_t`
/// can't capture Swift state, so they dispatch here via an
/// `Unmanaged` pointer and this class does the real logging under
/// normal Swift rules.
final class NTFSBlockDeviceContext {
    let resource: FSBlockDeviceResource
    let blockSize: Int
    let log: TaggedLogger
    /// Optional — populated for the long-lived mount context (set by
    /// loadResource before NTFSVolume init), nil for the short-lived
    /// probe context that's torn down before any IOStatsCollector
    /// exists. Present-vs-absent decides whether we record bdev stats
    /// or no-op.
    let stats: IOStatsCollector?

    init(resource: FSBlockDeviceResource, log: TaggedLogger, stats: IOStatsCollector? = nil) {
        self.resource = resource
        self.blockSize = Int(resource.blockSize)
        self.log = log
        self.stats = stats
    }

    func read(into buf: UnsafeMutableRawPointer, offset: off_t, length: Int) -> Int32 {
        let bs = max(blockSize, 512)
        let alignedOffset = (Int(offset) / bs) * bs
        let offsetDelta = Int(offset) - alignedOffset
        let alignedLength = ((offsetDelta + length + bs - 1) / bs) * bs

        let tmp = UnsafeMutableRawPointer.allocate(byteCount: alignedLength, alignment: bs)
        defer { tmp.deallocate() }

        let t0 = monotonicNanos()
        do {
            let rawBuf = UnsafeMutableRawBufferPointer(start: tmp, count: alignedLength)
            let bytesRead = try resource.read(into: rawBuf, startingAt: off_t(alignedOffset), length: alignedLength)
            if bytesRead < offsetDelta + length {
                log.error("bdev read short: off=\(offset) len=\(length) got=\(bytesRead)", scope: AppLogScope.io)
                stats?.recordBdevRead(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
                return EIO
            }
            memcpy(buf, tmp.advanced(by: offsetDelta), length)
            stats?.recordBdevRead(bytes: alignedLength, latencyNs: monotonicNanos() &- t0, error: false)
            return 0
        } catch {
            log.error("bdev read error: off=\(offset) len=\(length) err=\(error.localizedDescription)", scope: AppLogScope.io)
            stats?.recordBdevRead(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
            return EIO
        }
    }

    /// Read-modify-write wrapper. Reads via plain `read` (works during
    /// loadResource) and writes via `metadataWrite` (plain `write`
    /// returns EBADF until the volume is fully activated).
    func write(from buf: UnsafeRawPointer, offset: off_t, length: Int) -> Int32 {
        let bs = max(blockSize, 512)
        let alignedOffset = (Int(offset) / bs) * bs
        let offsetDelta = Int(offset) - alignedOffset
        let alignedLength = ((offsetDelta + length + bs - 1) / bs) * bs

        let tmp = UnsafeMutableRawPointer.allocate(byteCount: alignedLength, alignment: bs)
        defer { tmp.deallocate() }

        let t0 = monotonicNanos()
        do {
            if offsetDelta != 0 || alignedLength != length {
                let readRaw = UnsafeMutableRawBufferPointer(start: tmp, count: alignedLength)
                _ = try resource.read(into: readRaw, startingAt: off_t(alignedOffset), length: alignedLength)
            }
            memcpy(tmp.advanced(by: offsetDelta), buf, length)

            let writeRaw = UnsafeRawBufferPointer(start: tmp, count: alignedLength)
            try resource.metadataWrite(from: writeRaw,
                                       startingAt: off_t(alignedOffset),
                                       length: alignedLength)
            stats?.recordBdevWrite(bytes: alignedLength, latencyNs: monotonicNanos() &- t0, error: false)
            return 0
        } catch {
            log.error("bdev metadataWrite error: off=\(offset) len=\(length) err=\(error.localizedDescription)", scope: AppLogScope.io)
            stats?.recordBdevWrite(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
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
        log.info("probe called", scope: AppLogScope.probe)
        guard let blockDevice = resource as? FSBlockDeviceResource else {
            log.warn("probe: resource is not a block device — not recognized", scope: AppLogScope.probe)
            replyHandler(.notRecognized, nil)
            return
        }
        let dlog = TaggedLogger(
            log, fields: ["bsd": blockDevice.bsdName], kind: "ntfs.probe",
            scope: AppLogScope.probe
        )
        dlog.info("probe \(blockDevice.bsdName): blockSize=\(blockDevice.blockSize) blockCount=\(blockDevice.blockCount)")

        do {
            var buf = Data(count: 512)
            let bytesRead = try buf.withUnsafeMutableBytes { rawBuf in
                try blockDevice.read(into: rawBuf, startingAt: 0, length: 512)
            }

            guard bytesRead >= 12 else {
                dlog.info("probe: read \(bytesRead) bytes (< 12) — not NTFS")
                replyHandler(.notRecognized, nil)
                return
            }

            let oemID = String(bytes: buf[3..<11], encoding: .ascii) ?? ""
            guard oemID == "NTFS    " else {
                dlog.info("probe: OEM ID '\(oemID)' — not NTFS")
                replyHandler(.notRecognized, nil)
                return
            }

            let serial: UInt64 = buf.withUnsafeBytes { rawBuf in
                rawBuf.load(fromByteOffset: 0x48, as: UInt64.self)
            }
            dlog.info("probe: recognized NTFS volume (serial=0x\(String(serial, radix: 16)))")

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
            let probeContext = NTFSBlockDeviceContext(resource: blockDevice, log: dlog)
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
                dlog.warn("probe: volume label lookup failed — \(err); using fallback 'NTFS'")
            }

            dlog.info("probe: label=\"\(label)\"")
            replyHandler(.usable(name: label, containerID: containerID), nil)
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
        // All subsequent log lines carry `fields["bsd"]` so the
        // partition detail view's per-disk log strip picks them up.
        let dlog = TaggedLogger(
            log, fields: ["bsd": bsdName], kind: "ntfs.load",
            scope: AppLogScope.lifecycle
        )
        dlog.info("loadResource \(bsdName): blockSize=\(blockDevice.blockSize) blockCount=\(blockDevice.blockCount) isWritable=\(blockDevice.isWritable) taskOptions=\(options.taskOptions)")

        // One stats collector per mount — lives until NTFSVolume.deactivate.
        // The block-device callbacks made during fsck + RW remount in
        // `NTFSVolume.activate` flow through the SAME context object
        // we hand to FSKit here, so they get counted too.
        let stats = IOStatsCollector(label: bsdName, log: dlog)
        let context = NTFSBlockDeviceContext(resource: blockDevice, log: dlog, stats: stats)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        // Mirror the EXT4 fix: the kernel-level write FD on the
        // FSBlockDeviceResource only becomes truly writable AFTER
        // loadResource returns. Doing the dirty-check / $LogFile reset
        // here fails with "Bad file descriptor" on the first metadata
        // write. So we always mount RO during load and, if the resource
        // is writable, defer fsck + an RW remount to
        // `NTFSVolume.activate(options:)` where the FD is live.
        let isWritable = blockDevice.isWritable
        let cfgSizeBytes = blockDevice.blockCount * blockDevice.blockSize

        var cfg = fs_ntfs_blockdev_cfg_t()
        cfg.read = { ctx, buf, offset, length in
            guard let ctx = ctx, let buf = buf else { return EIO }
            let context = Unmanaged<NTFSBlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
            return context.read(into: buf, offset: off_t(offset), length: Int(length))
        }
        cfg.write = nil
        cfg.context = contextPtr
        cfg.size_bytes = cfgSizeBytes

        dlog.info("calling fs_ntfs_mount_with_callbacks (RO during load) size=\(cfg.size_bytes) blockSize=\(blockDevice.blockSize)")

        guard let bridgeFS = fs_ntfs_mount_with_callbacks(&cfg) else {
            let err = fs_ntfs_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
            dlog.error("fs_ntfs mount failed (RO): \(err)")
            Unmanaged<NTFSBlockDeviceContext>.fromOpaque(contextPtr).release()
            replyHandler(nil, POSIXError(.EIO))
            return
        }
        dlog.info("fs_ntfs mount succeeded (RO during load; will remount RW in activate if writable)")

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
            blockDevice: blockDevice,
            contextPtr: contextPtr,
            cfgSizeBytes: cfgSizeBytes,
            bsdName: bsdName,
            requiresFsckRemount: isWritable,
            stats: stats
        )
        // Begin emitting `io.stats` heartbeats now. The collector
        // self-suppresses idle ticks.
        stats.start()

        // CRITICAL: matches EXT4 pattern. Without this, fskitd never gets
        // the "load completed" signal and subsequent operations on the
        // resource fail with EAGAIN ("Resource temporarily unavailable").
        containerStatus = .ready
        dlog.info("volume ready: \"\(resolvedName)\"")
        dlog.event(kind: "volume.info", fields: [
            "fs": "ntfs",
            "volume_name": resolvedName,
            "cluster_size": "\(volInfo.cluster_size)",
            "total_clusters": "\(volInfo.total_clusters)",
            "total_size": "\(volInfo.total_size)",
            "ntfs_version": "\(volInfo.ntfs_version_major).\(volInfo.ntfs_version_minor)",
            "serial_number": "0x\(String(volInfo.serial_number, radix: 16))",
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
