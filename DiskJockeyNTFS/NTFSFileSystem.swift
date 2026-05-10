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
import DiskJockeyLibrary

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

    /// Flush kernel buffer cache to disk. Mirrors EXT4's BlockDeviceContext.flush.
    /// fs_ntfs's own callback shape (`fs_ntfs_blockdev_cfg_t`) has no flush
    /// field, so this is only reached through the qcow2-stacking path
    /// (FsCoreCallbackCfg.flush) — qcow2 needs the explicit flush after
    /// metadata writes for crash safety.
    func flush() -> Int32 {
        do {
            try resource.metadataFlush()
            return 0
        } catch {
            log.error("bdev metadataFlush error: \(error.localizedDescription)", scope: AppLogScope.io)
            return EIO
        }
    }
}

/// Disk-image container kinds the NTFS extension knows how to unwrap.
/// Mirrored on the EXT4 side (EXT4FileSystem.ContainerKind).
enum NTFSContainerKind: String, CustomStringConvertible {
    case qcow2, vhd, vhdx, vmdk
    var description: String { rawValue }

    /// Probe the resource (offset 0 + trailing footer for VHD-fixed).
    /// Returns nil when the bytes look like a raw NTFS partition image.
    static func detect(context: NTFSBlockDeviceContext, sizeBytes: UInt64) -> NTFSContainerKind? {
        var head = [UInt8](repeating: 0, count: 16)
        let rc = head.withUnsafeMutableBufferPointer { buf -> Int32 in
            return context.read(into: buf.baseAddress!, offset: 0, length: 16)
        }
        if rc == 0 {
            if head[0] == 0x51 && head[1] == 0x46
                && head[2] == 0x49 && head[3] == 0xFB { return .qcow2 }
            let vhdx: [UInt8] = [0x76, 0x68, 0x64, 0x78, 0x66, 0x69, 0x6c, 0x65]
            if Array(head.prefix(8)) == vhdx { return .vhdx }
            let vmdk: [UInt8] = [0x4b, 0x44, 0x4d, 0x56]
            if Array(head.prefix(4)) == vmdk { return .vmdk }
            let conectix: [UInt8] = [0x63, 0x6f, 0x6e, 0x65, 0x63, 0x74, 0x69, 0x78]
            if Array(head.prefix(8)) == conectix { return .vhd }
        }
        if sizeBytes >= 512 {
            var footer = [UInt8](repeating: 0, count: 8)
            let frc = footer.withUnsafeMutableBufferPointer { buf -> Int32 in
                return context.read(into: buf.baseAddress!,
                                    offset: off_t(sizeBytes - 512),
                                    length: 8)
            }
            let conectix: [UInt8] = [0x63, 0x6f, 0x6e, 0x65, 0x63, 0x74, 0x69, 0x78]
            if frc == 0 && footer == conectix { return .vhd }
        }
        return nil
    }

    /// Construct the right `*_open*_on_device` call. Consumes `inner`.
    static func open(kind: NTFSContainerKind,
                     inner: OpaquePointer,
                     writable: Bool) -> OpaquePointer? {
        switch kind {
        case .qcow2: return writable ? qcow2_open_rw_on_device(inner) : qcow2_open_on_device(inner)
        case .vhd:   return writable ? vhd_open_rw_on_device(inner)   : vhd_open_on_device(inner)
        case .vhdx:  return writable ? vhdx_open_rw_on_device(inner)  : vhdx_open_on_device(inner)
        case .vmdk:  return writable ? vmdk_open_rw_on_device(inner)  : vmdk_open_on_device(inner)
        }
    }
}

@objc(NTFSFileSystem)
final class NTFSFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    /// FSKit's `startCheck(task:options:)` hands us no resource handle —
    /// only an `FSTask` + `FSTaskOptions`. To route an explicit fsck
    /// back to the right mounted volume we register
    /// `(bsdName, NTFSVolume)` keyed by resource identity at
    /// `loadResource` time and look it up in `startCheck`. Cleared on
    /// `unloadResource`.
    ///
    /// Keyed by `ObjectIdentifier(FSResource)` — FSKit hands us the same
    /// FSResource instance for the lifetime of the mount, so the
    /// in-process pointer is a stable, unique handle. Guarded by an
    /// unfair lock so `startCheck` can read it without awaiting an
    /// actor. Mirror of the EXT4 extension's `mountedResources`.
    struct MountedResource {
        let bsdName: String
        let volume: NTFSVolume
        /// Retained `NTFSBlockDeviceContext` pointer the load path used
        /// to drive the FSBlockDeviceResource via C callbacks. Carried
        /// so `startFormat` can build a fresh `fs_ntfs_blockdev_cfg_t`
        /// against the same device. Mirror of EXT4's contextPtr.
        let contextPtr: UnsafeMutableRawPointer
        /// `cfg.size_bytes` captured at load time so format can rebuild
        /// the cfg without re-reading from the resource.
        let cfgSizeBytes: UInt64
        /// Cooperative tri-state mutex coordinating verify and repair
        /// on this volume. Mirror of EXT4's opLock — see
        /// `OperationLock` for the contract.
        let opLock: OperationLock
    }
    static let mountedResources = OSAllocatedUnfairLock<[ObjectIdentifier: MountedResource]>(
        initialState: [:])

    override init() {
        super.init()
        // Mach-service listener for the host app's in-process repair
        // bridge. Idempotent — start() guards against a second
        // FSUnaryFileSystem instance double-registering.
        RepairXPCService.shared.start()
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
        // Wrap the per-mount logger as the recorder's emit closure so
        // the shared `IOStatsRecorder` (in DiskJockeyLibrary) doesn't
        // need to import any logger type — AppLog stays per-extension.
        let stats = IOStatsRecorder(label: bsdName, emit: { fields in
            dlog.event(kind: "io.stats", fields: fields, scope: AppLogScope.stats)
        })
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

        // Detect a known disk-image container (QCOW2, VHD, VHDX, VMDK)
        // and stack the appropriate reader before NTFS. The initial
        // mount during loadResource is always RO — the kernel FD on
        // FSBlockDeviceResource isn't truly writable until
        // loadResource returns; NTFSVolume.activate's deferred remount
        // switches to fs_ntfs_mount_rw_with_fs_core_device with full
        // dirty-check + fsck via the matching `_with_fs_core_device`
        // entry points.
        let containerKind = NTFSContainerKind.detect(context: context, sizeBytes: cfgSizeBytes)
        let bridgeFS: OpaquePointer?
        if let kind = containerKind {
            dlog.info("\(kind) magic detected on resource — stacking \(kind) reader before NTFS mount (RO during load; activate will remount RW with fsck if writable=\(isWritable))")

            var coreCfg = FsCoreCallbackCfg()
            coreCfg.read = { ctx, offset, buf, len in
                guard let ctx = ctx, let buf = buf else { return EIO }
                let context = Unmanaged<NTFSBlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                return context.read(into: UnsafeMutableRawPointer(buf), offset: off_t(offset), length: Int(len))
            }
            coreCfg.write = nil   // RO mount during load
            coreCfg.flush = nil
            coreCfg.ctx = contextPtr
            coreCfg.size = cfgSizeBytes

            guard let innerHandle = withUnsafePointer(to: &coreCfg, { fs_core_device_from_callbacks($0) }) else {
                let err = fs_core_last_error_message().flatMap { String(cString: $0) } ?? "(no error set)"
                dlog.error("fs_core_device_from_callbacks failed for \(kind) backing: \(err)")
                Unmanaged<NTFSBlockDeviceContext>.fromOpaque(contextPtr).release()
                replyHandler(nil, POSIXError(.EIO))
                return
            }
            guard let containerHandle = NTFSContainerKind.open(kind: kind, inner: innerHandle, writable: false) else {
                let err = fs_core_last_error_message().flatMap { String(cString: $0) } ?? "(no error set)"
                dlog.error("\(kind)_open_on_device failed: \(err)")
                Unmanaged<NTFSBlockDeviceContext>.fromOpaque(contextPtr).release()
                replyHandler(nil, POSIXError(.EIO))
                return
            }
            dlog.info("calling fs_ntfs_mount_with_fs_core_device (\(kind) stacked, RO)")
            bridgeFS = fs_ntfs_mount_with_fs_core_device(containerHandle)
            fs_core_device_close(containerHandle)
        } else {
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
            bridgeFS = fs_ntfs_mount_with_callbacks(&cfg)
        }

        guard let bridgeFS = bridgeFS else {
            let err = fs_ntfs_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
            let suffix = containerKind.map { ", \($0)" } ?? ""
            dlog.error("fs_ntfs mount failed (RO\(suffix)): \(err)")
            Unmanaged<NTFSBlockDeviceContext>.fromOpaque(contextPtr).release()
            replyHandler(nil, POSIXError(.EIO))
            return
        }
        let containerSuffix = containerKind.map { ", \($0)-backed" } ?? ""
        dlog.info("fs_ntfs mount succeeded (RO during load\(containerSuffix); will remount RW in activate if writable)")

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
            // Container-backed NTFS uses NTFSVolume's deferred remount
            // (performDeferredContainerRwRemount) which goes through
            // fs_ntfs_{is_dirty,fsck,mount_rw}_with_fs_core_device on the
            // stacked container handle.
            requiresFsckRemount: isWritable,
            containerKind: containerKind,
            stats: stats
        )
        // Stash volume + bsdName + contextPtr + size so `startCheck`
        // and `startFormat` (both called without a resource handle)
        // can find them. Lifecycle matches the volume's; freed in
        // NTFSVolume.deactivate.
        Self.mountedResources.withLock { map in
            map[ObjectIdentifier(resource)] = MountedResource(
                bsdName: bsdName, volume: volume,
                contextPtr: contextPtr, cfgSizeBytes: cfgSizeBytes,
                opLock: OperationLock())
        }
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
        Self.mountedResources.withLock { map in
            map.removeValue(forKey: ObjectIdentifier(resource))
        }
        reply(nil)
    }

    func didFinishLoading() {
    }
}

// fskitd calls `_checkResource:` on every mount (not just explicit fsck)
// to decide whether to go down the check/repair path. Without this
// conformance the call returns ENOTSUP (POSIX 45) and the system
// refuses to mount.
extension NTFSFileSystem: FSManageableResourceMaintenanceOperations {
    /// Run an NTFS fsck pass driven by the rust crate's
    /// `fs_ntfs_fsck_with_callbacks`. Emits NDJSON events the host app's
    /// `AttachedDisksModel` consumes: `fsck.start`, `fsck.progress`,
    /// `fsck.done`, `fsck.failed`.
    ///
    /// Shape parity with `EXT4FileSystem.startCheck`: the body is
    /// intentionally near-identical — only the resolved type
    /// (`NTFSVolume` vs `EXT4Backend`), the dlog `kind`, and the
    /// progress-tracker phase weights differ. `runFsck` is pure on
    /// both extensions, so all event emission lives here.
    ///
    /// `FSManageableResourceMaintenanceOperations` does NOT pass us a
    /// resource handle (see header comment on `mountedResources`).
    /// Since `FSUnaryFileSystem` instances host one mount at a time we
    /// resolve the mount by reading the single entry. If multiple are
    /// ever registered (hypothetical multi-volume FSKit future) we fail
    /// loudly rather than guess.
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        let resolved: MountedResource? = Self.mountedResources.withLock { map in
            guard !map.isEmpty else { return nil }
            if map.count == 1 { return map.values.first }
            return nil
        }

        guard let resolved = resolved else {
            log.error("startCheck: no (or ambiguous) mounted resource registered — refusing", scope: AppLogScope.fsck)
            throw POSIXError(.EBADF)
        }
        let bsdName = resolved.bsdName
        let volume = resolved.volume
        let opLock = resolved.opLock
        let dlog = TaggedLogger(
            log, fields: ["bsd": bsdName], kind: "ntfs.fsck",
            scope: AppLogScope.fsck
        )

        // Cooperative tri-state mutex. NTFS verify is currently the
        // only flavor (`runFsck` is read-only on this side; a future
        // repair pass would acquire `.repair` instead). Reject
        // up-front if the volume is busy.
        if let busy = opLock.tryAcquire(.verify) {
            dlog.warn("startCheck rejected: volume busy with \(busy.displayName)")
            throw POSIXError(.EBUSY)
        }

        // Pin Progress at 100 total units; the tracker bumps
        // `completedUnitCount` per phase as the rust crate reports.
        // The rust fsck has no cancel hook, so we don't wire a
        // `cancellationHandler`.
        let progress = Progress(totalUnitCount: 100)

        dlog.event(kind: "fsck.start", fields: [:])

        let tracker = FsckProgressTracker()

        // Throttle fsck.progress emission. Mirror of the throttle in
        // EXT4FileSystem.startCheck — see that comment for the
        // rationale. Without this, every callback hops to the host's
        // main actor and beachballs the UI on a multi-thousand-record
        // volume. NSProgress.completedUnitCount keeps updating every
        // callback so the FSKit-side bar stays smooth.
        let appGroupDefaults = UserDefaults(suiteName: AppLog.groupIdentifier)
        let verbose = appGroupDefaults?.bool(forKey: "verboseRepairLog") ?? false
        let minIntervalNs: UInt64 = verbose ? 100_000_000 : 1_000_000_000
        var lastEmitMonotonic: UInt64 = 0
        var lastPhase: String = ""

        // Detached so the closure isn't tied to any actor; the C
        // callbacks fire on rust's worker thread anyway. Concurrent
        // reads/writes on the volume will fail while fsck runs (we drop
        // bridgeFS before the dirty check) — that's expected; fsck
        // temporarily takes the volume offline. opLock release sits
        // here because the operation continues asynchronously.
        Task.detached {
            defer { opLock.release() }
            let result = volume.runFsck(
                onProgress: { phase, done, total in
                    let now = monotonicNanos()
                    let phaseChanged = phase != lastPhase
                    let intervalElapsed = lastEmitMonotonic == 0
                        || (now &- lastEmitMonotonic) >= minIntervalNs
                    if phaseChanged || intervalElapsed {
                        lastEmitMonotonic = now
                        lastPhase = phase
                        dlog.event(kind: "fsck.progress", fields: [
                            "phase": phase,
                            "done":  "\(done)",
                            "total": "\(total)",
                        ])
                    }
                    let units = tracker.observe(phase: phase, done: done, total: total)
                    progress.completedUnitCount = units
                },
                onFinding: { _ in
                    // NTFS has no per-finding callback; closure unused.
                }
            )

            switch result {
            case .success(let report):
                dlog.event(kind: "fsck.done", fields: report.toEventFields())
                progress.completedUnitCount = 100
                task.didComplete(error: nil)

            case .failure(let err):
                dlog.event(kind: "fsck.failed", fields: [
                    "error": "\(err)",
                ])
                task.didComplete(error: err)
            }
        }

        return progress
    }

    /// Start formatting the resource as NTFS. Mirror of the EXT4
    /// extension's `startFormat` — see comments there + see
    /// `docs/fskit-format-pipeline.md` for the FSKit limitations and
    /// safety caveats. Same single-mount-required, same kernel-cache
    /// risk if the volume is actively mounted.
    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        let resolved: MountedResource? = Self.mountedResources.withLock { map in
            guard !map.isEmpty else { return nil }
            if map.count == 1 { return map.values.first }
            return nil
        }
        guard let resolved = resolved else {
            log.error(
                "startFormat: no loaded resource to format — disk must be probed/loaded first; see docs/fskit-format-pipeline.md",
                scope: AppLogScope.fsck
            )
            throw POSIXError(.ENOTSUP)
        }
        let bsdName = resolved.bsdName
        let dlog = TaggedLogger(
            log, fields: ["bsd": bsdName], kind: "ntfs.format",
            scope: AppLogScope.fsck
        )
        dlog.info("startFormat \(bsdName): taskOptions=\(options.taskOptions)")

        // -L <label> from argv (newfs_fskit forwards user args verbatim).
        var label: String? = nil
        let argv = options.taskOptions
        if let idx = argv.firstIndex(of: "-L"), idx + 1 < argv.count {
            label = argv[idx + 1]
        }

        let progress = Progress(totalUnitCount: 100)
        dlog.event(kind: "format.start", fields: ["label": label ?? ""])

        Task.detached {
            // Same callback-cfg construction as the mount path — see
            // NTFSFileSystem.loadResource for the original. Reuses the
            // retained NTFSBlockDeviceContext so writes go through the
            // FSBlockDeviceResource just like a mounted-time write.
            let bdc = resolved.contextPtr
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
            cfg.context = bdc
            cfg.size_bytes = resolved.cfgSizeBytes

            // The Rust `fs_ntfs::mkfs::format_filesystem` accepts a
            // label, but the current C ABI export `fs_ntfs_mkfs(cfg)`
            // hard-codes `None`. Extending the C ABI to accept a label
            // (matching `fs_ext4_mkfs`) is straightforward follow-up
            // work — for now formatting is "no label, no serial,
            // 4096-byte clusters, 4096-byte MFT records". Caller's
            // -L argv is ignored with a warn so the user sees the gap.
            if let l = label {
                dlog.warn("ignoring -L \(l): fs_ntfs_mkfs C ABI does not yet accept a label; format will produce a no-label volume")
            }
            let rc = fs_ntfs_mkfs(&cfg)

            if rc == 0 {
                dlog.event(kind: "format.done", fields: [:])
                progress.completedUnitCount = 100
                task.didComplete(error: nil)
            } else {
                let err = fs_ntfs_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
                dlog.event(kind: "format.failed", fields: ["error": err], level: .error)
                task.didComplete(error: POSIXError(.EIO))
            }
        }

        return progress
    }
}

/// Maps the rust crate's phase/done/total stream onto a 0-100
/// `NSProgress.completedUnitCount`. Mirror of `EXT4FileSystem`'s
/// `FsckProgressTracker` with NTFS-specific phase weights — the rust
/// crate emits `"reset_logfile"` (long, byte-count progress) and
/// `"clear_dirty"` (single tick around a 2-byte write).
///
/// Lock guards the mutable cursor so callbacks fired from the rust
/// thread are serialised against any future caller.
final class FsckProgressTracker: @unchecked Sendable {
    private struct State {
        var lastPhase: String = ""
        var completedFloor: Int64 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    private static let totalUnits: Int64 = 100
    private static let phaseWeight: [String: Int64] = [
        "reset_logfile": 90,
        "clear_dirty":   10,
    ]

    func observe(phase: String, done: UInt64, total: UInt64) -> Int64 {
        return state.withLock { s -> Int64 in
            if phase != s.lastPhase {
                if !s.lastPhase.isEmpty {
                    s.completedFloor += Self.phaseWeight[s.lastPhase] ?? 0
                }
                s.lastPhase = phase
            }
            let weight = Self.phaseWeight[phase] ?? 0
            let intra: Int64
            if total == 0 {
                intra = 0
            } else {
                let ratio = max(0.0, min(1.0, Double(done) / Double(total)))
                intra = Int64(Double(weight) * ratio)
            }
            return min(Self.totalUnits, s.completedFloor + intra)
        }
    }
}
