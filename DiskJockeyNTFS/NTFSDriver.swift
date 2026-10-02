/*
 * NTFSDriver.swift — the fs_ntfs_* and fs_core_* C ABI behind NTFSBackend.
 *
 * The only file in this extension that calls the driver on behalf of the
 * volume, so that NTFSVolume.swift builds without the Rust static library
 * and `swift test` can run it (DiskJockeyNTFSCore in Package.swift, which
 * excludes this file). Each I/O method is one C call and the conversion of
 * its C types into NTFSBackend's Swift ones. The lifecycle methods — fsck,
 * and the deferred read-write remount through a device chain — are the
 * unmount / dirty-check / fsck / remount sequences that used to sit in
 * NTFSVolume, moved here unchanged because every step of them is a C call.
 *
 * MIT License — see LICENSE
 */

import Foundation
import DiskJockeyLibrary

final class NTFSDriver: NTFSBackend {

    /// The mounted filesystem. Replaced by `fsck` and the deferred
    /// remount; nil once unmounted.
    private var fs: OpaquePointer?

    /// Retained block-device callback context (`BlockDeviceContext`).
    /// Held as an opaque pointer so the C callbacks can deref it the same
    /// way they do during the initial mount in
    /// `NTFSFileSystem.loadResource`. Released by `releaseDevice()` after
    /// `fs_ntfs_umount` — the Rust handle's captured callbacks are gone by
    /// then so the pointer is safe to drop.
    private var contextPtr: UnsafeMutableRawPointer?

    /// `cfg.size_bytes` captured at load time (block_count * block_size),
    /// reused when the cfg is rebuilt for fsck + RW remount.
    private let cfgSizeBytes: UInt64

    /// BSD device name (e.g. `disk5s1`), for the deferred remount's log.
    private let bsdName: String

    /// Set when the resource sits inside a known disk-image container
    /// (qcow2, vhd, vhdx, vmdk). nil = raw NTFS partition image.
    private let containerKind: NTFSContainerKind?

    /// Set when this volume is one partition of a larger device. The
    /// deferred remount slices the (possibly container-wrapped) device at
    /// [offset, offset+length) before mounting fs_ntfs.
    private let partitionOffset: UInt64?
    private let partitionLength: UInt64?

    init(fs: OpaquePointer,
         contextPtr: UnsafeMutableRawPointer,
         cfgSizeBytes: UInt64,
         bsdName: String,
         containerKind: NTFSContainerKind? = nil,
         partitionOffset: UInt64? = nil,
         partitionLength: UInt64? = nil) {
        self.fs = fs
        self.contextPtr = contextPtr
        self.cfgSizeBytes = cfgSizeBytes
        self.bsdName = bsdName
        self.containerKind = containerKind
        self.partitionOffset = partitionOffset
        self.partitionLength = partitionLength
    }

    /// Runs one driver call with the thread's error state cleared first.
    ///
    /// am-fs-ntfs 0.5.0 never clears its thread-local errno on success, and
    /// some of its failures (a NULL or non-UTF-8 path, an unwritable
    /// handle) return the sentinel without setting one. Without the clear,
    /// `lastErrno()` after such a failure is whatever an earlier call on
    /// this thread left — typically the ENOENT of any lookup of a missing
    /// name — and the volume would report that stale reason as this one's.
    /// (rust-fs-ntfs#381)
    private func call<T>(_ body: () -> T) -> T {
        fs_ntfs_clear_last_error()
        return body()
    }

    // MARK: - Reading

    func volumeInfo() -> NTFSVolumeInfo? {
        guard let fs else { return nil }
        var info = fs_ntfs_volume_info_t()
        // The return code was never consulted; a zeroed info is what a
        // failure leaves, and it is reported as zero-sized.
        _ = call { fs_ntfs_get_volume_info(fs, &info) }
        return NTFSVolumeInfo(clusterSize: info.cluster_size,
                              totalClusters: info.total_clusters)
    }

    func stat(_ path: VolumePath) -> NTFSFileAttributes? {
        guard let fs else { return nil }
        var attr = fs_ntfs_attr_t()
        guard call({ path.withCString { fs_ntfs_stat(fs, $0, &attr) } }) == 0 else {
            return nil
        }
        return NTFSFileAttributes(
            recordNumber: attr.file_record_number,
            size: attr.size,
            accessTime: (attr.atime_sec, attr.atime_nsec),
            modifyTime: (attr.mtime_sec, attr.mtime_nsec),
            changeTime: (attr.ctime_sec, attr.ctime_nsec),
            creationTime: (attr.crtime_sec, attr.crtime_nsec),
            mode: attr.mode,
            linkCount: attr.link_count,
            fileType: NTFSFileType(raw: attr.file_type.rawValue),
            fileAttributes: attr.attributes)
    }

    func walkDirectory(_ path: VolumePath,
                       _ visit: (NTFSDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk {
        guard let fs,
              let iter = call({ path.withCString { fs_ntfs_dir_open(fs, $0) } }) else {
            return .openFailed
        }
        defer { fs_ntfs_dir_close(iter) }
        while let de = fs_ntfs_dir_next(iter) {
            // By `name_len`, sized from the imported array: the header's
            // array is FS_NTFS_DIRENT_NAME_BYTES (1024), and a 255-unit
            // NTFS name is up to 765 bytes of UTF-8 (diskjockey#244).
            guard let name = DirentName.bytes(
                of: de.pointee.name, length: Int(de.pointee.name_len)
            ) else {
                return .failedPartway
            }
            let entry = NTFSDirectoryEntry(
                name: name,
                recordNumber: de.pointee.file_record_number,
                fileType: NTFSFileType(raw: UInt32(de.pointee.file_type)))
            if !visit(entry) { return .finished }
        }
        // NULL here is the end, and the errno is deliberately not asked.
        // fs_ntfs_dir_open materialises the whole listing before it
        // returns, so fs_ntfs_dir_next only steps through a list it already
        // holds and has nothing left to fail on. am-fs-ntfs 0.5.0 never
        // clears its errno on success either, so reading it here would
        // turn every listing after one failed lookup on this thread into
        // a failure.
        return .finished
    }

    func read(_ path: VolumePath, at offset: UInt64,
              into buffer: UnsafeMutableRawBufferPointer) -> Int64 {
        guard let fs else { return -1 }
        return call {
            path.withCString {
                fs_ntfs_read_file(fs, $0, buffer.baseAddress, offset, UInt64(buffer.count))
            }
        }
    }

    func readlink(_ path: VolumePath, _ buffer: UnsafeMutablePointer<CChar>,
                  _ size: Int) -> Int32 {
        guard let fs else { return -1 }
        return call { path.withCString { fs_ntfs_readlink(fs, $0, buffer, size) } }
    }

    // MARK: - Writing

    func writeContents(_ path: VolumePath, _ bytes: UnsafeRawBufferPointer) -> Int64 {
        guard let fs, let base = bytes.baseAddress else { return -1 }
        return call {
            path.withCString {
                fs_ntfs_write_file_contents_h(fs, $0, base, UInt64(bytes.count))
            }
        }
    }

    func truncate(_ path: VolumePath, to size: UInt64) -> Int64 {
        guard let fs else { return -1 }
        return call { path.withCString { fs_ntfs_truncate_h(fs, $0, size) } }
    }

    func createFile(in parent: VolumePath, named name: String) -> Int64 {
        guard let fs else { return -1 }
        return call { parent.withCString { fs_ntfs_create_file_h(fs, $0, name) } }
    }

    func mkdir(in parent: VolumePath, named name: String) -> Int64 {
        guard let fs else { return -1 }
        return call { parent.withCString { fs_ntfs_mkdir_h(fs, $0, name) } }
    }

    func unlink(_ path: VolumePath) -> Int32 {
        guard let fs else { return -1 }
        return call { path.withCString { fs_ntfs_unlink_h(fs, $0) } }
    }

    func rmdir(_ path: VolumePath) -> Int32 {
        guard let fs else { return -1 }
        return call { path.withCString { fs_ntfs_rmdir_h(fs, $0) } }
    }

    func rename(_ path: VolumePath, toBasename name: String) -> Int32 {
        guard let fs else { return -1 }
        return call {
            path.withCString { fs_ntfs_rename2_h(fs, $0, name, FS_NTFS_RENAME_REPLACE) }
        }
    }

    func setTimes(_ path: VolumePath, _ times: NTFSFileTimes) -> Int32 {
        guard let fs else { return -1 }
        // Pack all four timestamps into a contiguous buffer so each slot
        // can be passed as a pointer or nil without four levels of nesting.
        let values: ContiguousArray<Int64> = [times.creation ?? 0, times.modification ?? 0,
                                              times.change ?? 0, times.access ?? 0]
        return values.withUnsafeBufferPointer { buf in
            call {
                path.withCString {
                    fs_ntfs_set_times_h(
                        fs, $0,
                        times.creation != nil     ? buf.baseAddress      : nil,
                        times.modification != nil ? buf.baseAddress! + 1 : nil,
                        times.change != nil       ? buf.baseAddress! + 2 : nil,
                        times.access != nil       ? buf.baseAddress! + 3 : nil)
                }
            }
        }
    }

    func lastErrno() -> Int32 {
        Int32(fs_ntfs_last_errno())
    }

    // MARK: - Lifecycle

    var isMounted: Bool { fs != nil }

    var remountsThroughDeviceChain: Bool {
        containerKind != nil || partitionOffset != nil
    }

    func unmount() {
        if let fs {
            fs_ntfs_umount(fs)
            self.fs = nil
        }
    }

    func releaseDevice() {
        if let ctx = contextPtr {
            Unmanaged<BlockDeviceContext>.fromOpaque(ctx).release()
            contextPtr = nil
        }
    }

    /// Box for the Swift closure the C progress callback dispatches to.
    /// Required because `@convention(c)` callbacks (which Rust expects)
    /// cannot capture Swift state — we pass `Unmanaged.passRetained(...)
    /// .toOpaque()` as the `progress_ctx` and unwrap inside the C
    /// closure. Mirrors `EXT4Backend.FsckCallbackBox`.
    private final class FsckProgressBox {
        let onProgress: (_ phase: String, _ done: UInt64, _ total: UInt64) -> Void
        init(onProgress: @escaping (_ phase: String, _ done: UInt64, _ total: UInt64) -> Void) {
            self.onProgress = onProgress
        }
    }

    /// The unmount→dirty-check→fsck→remount lifecycle is non-negotiable:
    /// the rust crate refuses to call fsck against a mounted handle (it
    /// rewrites `$LogFile` + the dirty bit on the raw device, which would
    /// conflict with the in-memory view held by a live mount). Even on
    /// already-clean volumes we still do the cycle because we don't know
    /// the volume is clean until after the dirty check.
    func fsck(onProgress: @escaping (_ phase: String, _ done: UInt64, _ total: UInt64) -> Void)
        -> Result<NTFSVolume.FsckReport, Error> {
        // Drop any current handle before fsck. Safe to call when
        // fs is already nil — we just skip the umount.
        unmount()

        var cfg = fs_ntfs_blockdev_cfg_t()
        cfg.read = { ctx, buf, offset, length in
            guard let ctx = ctx, let buf = buf else { return EIO }
            let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
            return context.read(into: buf, offset: off_t(offset), length: Int(length))
        }
        cfg.write = { ctx, buf, offset, length in
            guard let ctx = ctx, let buf = buf else { return EIO }
            let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
            return context.write(from: buf, offset: off_t(offset), length: Int(length))
        }
        cfg.context = contextPtr
        cfg.size_bytes = cfgSizeBytes

        // Always remount before returning — even on errors — so the
        // volume stays usable. Captured here so every exit path runs it.
        func remount() {
            if let newFs = fs_ntfs_mount_with_callbacks(&cfg) {
                fs = newFs
            } else {
                cfg.write = nil
                fs = fs_ntfs_mount_with_callbacks(&cfg)
            }
        }

        let dirtyResult = fs_ntfs_is_dirty_with_callbacks(&cfg)
        switch dirtyResult {
        case 1:
            // Dirty — actually run fsck.
            let box = FsckProgressBox(onProgress: onProgress)
            let boxPtr = Unmanaged.passRetained(box).toOpaque()
            defer { Unmanaged<FsckProgressBox>.fromOpaque(boxPtr).release() }

            var dirtyCleared: UInt8 = 0
            let rc = fs_ntfs_fsck_with_callbacks(
                &cfg,
                { ctx, phase, done, total in
                    guard let ctx = ctx, let phase = phase else { return 0 }
                    let box = Unmanaged<FsckProgressBox>.fromOpaque(ctx).takeUnretainedValue()
                    box.onProgress(String(cString: phase), done, total)
                    return 0
                },
                boxPtr,
                &dirtyCleared
            )
            remount()
            if rc == 0 {
                return .success(NTFSVolume.FsckReport(
                    wasDirty: true,
                    dirtyCleared: dirtyCleared == 1
                ))
            }
            let msg = fs_ntfs_last_error().flatMap { String(cString: $0) } ?? "fs_ntfs_fsck_with_callbacks failed (rc=\(rc))"
            return .failure(NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(POSIXErrorCode.EIO.rawValue),
                userInfo: [NSLocalizedDescriptionKey: msg]
            ))

        case 0:
            // Clean — nothing to do, just remount and report.
            remount()
            return .success(NTFSVolume.FsckReport(wasDirty: false, dirtyCleared: false))

        default:
            // Dirty check itself failed.
            remount()
            let msg = fs_ntfs_last_error().flatMap { String(cString: $0) } ?? "fs_ntfs_is_dirty_with_callbacks failed"
            return .failure(NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(POSIXErrorCode.EIO.rawValue),
                userInfo: [NSLocalizedDescriptionKey: msg]
            ))
        }
    }

    /// Container-backed counterpart to the callback-based deferred
    /// remount. Tears down the RO mount, builds a writable
    /// container-stacked FsCoreDevice (qcow2 / vhd / vhdx / vmdk), runs
    /// the dirty check + fsck via the `_with_fs_core_device` family, then
    /// remounts RW. Mirrors the callback-based path exactly; only the
    /// device source differs.
    func remountReadWriteThroughDeviceChain() {
        let dlog = TaggedLogger(log, fields: ["bsd": bsdName], kind: "ntfs.activate",
                                scope: AppLogScope.lifecycle)
        let kindLabel = containerKind.map { "\($0)" } ?? "container"
        dlog.info("performing \(kindLabel) deferred RW remount (with fsck via fs_core_device)")

        unmount()

        // Build a writable container-stacked FsCoreDevice. We rebuild it
        // for each step (dirty check, fsck, mount) because each
        // `_with_fs_core_device` entry borrows the handle's inner Arc;
        // they're cheap (just callback wrapping + container header parse).
        guard let containerHandle = buildContainerHandle(rw: true, dlog: dlog) else {
            fallbackRemountRo()
            return
        }

        // Step 1: dirty check.
        let dirtyRC = fs_ntfs_is_dirty_with_fs_core_device(containerHandle)
        let wasDirty: Bool
        switch dirtyRC {
        case 0:
            wasDirty = false
            dlog.event(kind: "volume.clean", scope: AppLogScope.volume)
        case 1:
            wasDirty = true
            dlog.event(kind: "volume.dirty", scope: AppLogScope.volume)
        default:
            let err = fs_ntfs_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
            dlog.error("fs_ntfs_is_dirty_with_fs_core_device rc=\(dirtyRC) err=\(err)")
            fs_core_device_close(containerHandle)
            fallbackRemountRo()
            return
        }

        // Step 2: fsck only when dirty (matches the callback-based path).
        if wasDirty {
            dlog.event(kind: "fsck.start", scope: AppLogScope.fsck)
            var dirtyCleared: UInt8 = 0
            let rc = fs_ntfs_fsck_with_fs_core_device(
                containerHandle, nil, nil, &dirtyCleared
            )
            if rc != 0 {
                let err = fs_ntfs_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
                dlog.event(kind: "fsck.failed", fields: ["error": err],
                           level: .error, scope: AppLogScope.fsck)
                fs_core_device_close(containerHandle)
                fallbackRemountRo()
                return
            }
            dlog.event(kind: "fsck.done", fields: [
                "dirty_cleared": dirtyCleared == 1 ? "true" : "false",
            ], scope: AppLogScope.fsck)
        }

        // Step 3: remount RW. Reuse the same handle — fsck only borrowed.
        if let newFs = fs_ntfs_mount_rw_with_fs_core_device(containerHandle) {
            fs = newFs
            fs_core_device_close(containerHandle)
            dlog.info("\(kindLabel) RW remount succeeded\(wasDirty ? " (post-fsck)" : "")")
        } else {
            let err = fs_ntfs_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
            dlog.error("fs_ntfs_mount_rw_with_fs_core_device failed: \(err)")
            fs_core_device_close(containerHandle)
            fallbackRemountRo()
        }
    }

    /// Build an FsCoreDevice that wraps the container layer over a fresh
    /// callback-backed device. Caller owns + closes the returned
    /// handle. Returns nil on failure (logged + the inner devices
    /// released by the C ABI's ownership-transfer rules).
    private func buildContainerHandle(rw: Bool, dlog: TaggedLogger) -> OpaquePointer? {
        var coreCfg = FsCoreCallbackCfg()
        coreCfg.read = { ctx, offset, buf, len in
            guard let ctx = ctx, let buf = buf else { return EIO }
            let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
            return context.read(into: UnsafeMutableRawPointer(buf), offset: off_t(offset), length: Int(len))
        }
        if rw {
            coreCfg.write = { ctx, offset, buf, len in
                guard let ctx = ctx, let buf = buf else { return EIO }
                let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                return context.write(from: UnsafeRawPointer(buf), offset: off_t(offset), length: Int(len))
            }
            coreCfg.flush = { ctx in
                guard let ctx = ctx else { return EIO }
                let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                return context.flush()
            }
        } else {
            coreCfg.write = nil
            coreCfg.flush = nil
        }
        coreCfg.ctx = contextPtr
        coreCfg.size = cfgSizeBytes

        guard let inner = withUnsafePointer(to: &coreCfg, { fs_core_device_from_callbacks($0) }) else {
            let err = fs_core_last_error_message().flatMap { String(cString: $0) } ?? "(no error set)"
            dlog.error("fs_core_device_from_callbacks failed (rw=\(rw)): \(err)")
            return nil
        }

        var stacked: OpaquePointer = inner
        if let kind = containerKind {
            guard let h = NTFSContainerKind.open(kind: kind, inner: stacked, writable: rw) else {
                let err = fs_core_last_error_message().flatMap { String(cString: $0) } ?? "(no error set)"
                dlog.error("\(kind)_open\(rw ? "_rw" : "")_on_device failed: \(err)")
                return nil
            }
            stacked = h
        }

        if let off = partitionOffset, let len = partitionLength, off > 0 || len > 0 {
            guard let s = (rw ? fs_core_device_slice_rw(stacked, off, len)
                              : fs_core_device_slice_ro(stacked, off, len)) else {
                let err = fs_core_last_error_message().flatMap { String(cString: $0) } ?? "(no error set)"
                dlog.error("fs_core_device_slice_\(rw ? "rw" : "ro") failed: \(err)")
                fs_core_device_close(stacked)
                return nil
            }
            fs_core_device_close(stacked)  // slice keeps its own Arc
            return s
        }

        if containerKind == nil {
            // No container, no partition slice — the deferred-remount path
            // shouldn't have been called. Free + return nil so the caller
            // can fall back to a read-only remount.
            dlog.error("buildContainerHandle called on plain whole-disk volume; freeing handle")
            fs_core_device_close(stacked)
            return nil
        }

        return stacked
    }

    /// Rebuild a read-only container-stacked mount when the RW path
    /// fails. Keeps the volume usable (browsable) instead of leaving
    /// `fs` nil and every subsequent op failing with EIO.
    private func fallbackRemountRo() {
        let dlog = TaggedLogger(log, fields: ["bsd": bsdName], kind: "ntfs.activate",
                                scope: AppLogScope.lifecycle)
        guard let containerHandle = buildContainerHandle(rw: false, dlog: dlog) else {
            dlog.error("RO fallback: buildContainerHandle failed; volume is unusable until next mount")
            return
        }
        fs = fs_ntfs_mount_with_fs_core_device(containerHandle)
        fs_core_device_close(containerHandle)
        if fs != nil {
            dlog.info("RO fallback remount succeeded")
        }
    }
}
