/*
 * EXT4Backend.swift — FileSystemBackend wrapping the fs_ext4 C ABI.
 *
 * Translates protocol calls to fs_ext4_* functions exposed by libfs_ext4.a.
 * The fs_ext4 library is built from vendored source at vendor/rust-fs-ext4/
 * (git submodule) and output to vendor/fs_ext4/ via `make vendor-fs-ext4`.
 *
 * MIT License — see LICENSE
 */

import Foundation
import os

private let backendLogger = Logger(subsystem: "com.antimatterstudios.diskjockey.ext4", category: "backend")

// MARK: - @unchecked Sendable wrappers
//
// Three local escape hatches that opt out of strict-concurrency
// checking exactly at the points where the type system can't prove
// what we know to be safe. Each wrapper is `@unchecked Sendable`
// with a precise justification — the wrappers exist next to the
// unsafe-code they justify so a reader sees the "trust me" tag
// inline.

/// Holds the opaque `fs_ext4` handle inside the unfair lock.
/// `OpaquePointer`'s `Sendable` conformance is marked unavailable
/// in the standard library (pointers could in principle alias non-
/// Sendable data); we manually verify our handle is safe to share
/// because:
///   1. The Rust `fs_ext4` crate serialises per-handle internally
///      via `Arc<RwLock>`.
///   2. We additionally guard every access with `OSAllocatedUnfairLock`.
///   3. The closure body inside `withLock` stays synchronous
///      (no `await`).
private struct BridgeHandle: @unchecked Sendable {
    var ptr: OpaquePointer?
}

/// Carries a mutable raw pointer past the `withLock` @Sendable
/// closure boundary. The pointer's storage is the caller's
/// responsibility for the call duration; the lock's critical
/// section is synchronous so the capture's lifetime is bounded
/// by the FFI call.
private struct UncheckedMutableBuffer: @unchecked Sendable {
    let p: UnsafeMutableRawPointer
}

/// Read-only counterpart of `UncheckedMutableBuffer` for
/// `UnsafeRawPointer` parameters (the write path's `data` argument).
private struct UncheckedConstBuffer: @unchecked Sendable {
    let p: UnsafeRawPointer
}

final class EXT4Backend: FileSystemBackend {

    /// fs_ext4 serialises per-handle via Arc<RwLock> internally, but we still
    /// hold the handle + a matching Sendable-safe lock on the Swift side so
    /// the class is safe to hand across actor boundaries under Swift 6.
    /// The unfair lock guards `bridgeFS`; the closure body stays synchronous
    /// by construction (no `await`). Wrapped in `BridgeHandle` so the lock's
    /// `State` requirement (must be `Sendable`) is satisfied — the standard
    /// library marks `OpaquePointer`'s Sendable conformance unavailable.
    private let state: OSAllocatedUnfairLock<BridgeHandle>

    init(bridgeFS: OpaquePointer) {
        self.state = OSAllocatedUnfairLock(initialState: BridgeHandle(ptr: bridgeFS))
    }

    func volumeInfo() -> BackendVolumeInfo {
        state.withLock { handle in
            guard let fs = handle.ptr else {
                return BackendVolumeInfo(name: "ext4", blockSize: 4096,
                                        totalBlocks: 0, freeBlocks: 0,
                                        totalInodes: 0, freeInodes: 0,
                                        mountedDirty: false)
            }

            var info = fs_ext4_volume_info_t()
            fs_ext4_get_volume_info(fs, &info)

            return BackendVolumeInfo(
                name: Self.volumeName(from: &info),
                uuid: Self.uuidString(from: &info),
                lastMounted: Self.lastMountedPath(from: &info),
                blockSize: info.block_size,
                totalBlocks: info.total_blocks,
                freeBlocks: info.free_blocks,
                reservedBlocks: info.reserved_blocks,
                totalInodes: info.total_inodes,
                freeInodes: info.free_inodes,
                inodeSize: info.inode_size,
                firstInode: info.first_inode,
                blocksPerGroup: info.blocks_per_group,
                inodesPerGroup: info.inodes_per_group,
                creatorOS: info.creator_os,
                revLevel: info.rev_level,
                minorRevLevel: info.minor_rev_level,
                featureCompat: info.feature_compat,
                featureIncompat: info.feature_incompat,
                featureRoCompat: info.feature_ro_compat,
                descSize: info.desc_size,
                defaultHashVersion: info.default_hash_version,
                state: info.state,
                errorsBehavior: info.errors_behavior,
                lastMountTime: info.last_mount_time,
                lastWriteTime: info.last_write_time,
                lastCheckTime: info.last_check_time,
                checkInterval: info.check_interval,
                mountCount: info.mount_count,
                maxMountCount: info.max_mount_count,
                defResUID: info.def_resuid,
                defResGID: info.def_resgid,
                mountedDirty: info.mounted_dirty != 0
            )
        }
    }

    // MARK: - Volume-info helpers

    /// Returns the volume label, falling back to "ext4" for unlabelled volumes.
    private static func volumeName(from info: inout fs_ext4_volume_info_t) -> String {
        let raw = withUnsafePointer(to: info.volume_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        return raw.isEmpty ? "ext4" : raw
    }

    /// Formats the 16-byte UUID field as canonical RFC 4122 lowercase hex (8-4-4-4-12)
    /// so it round-trips with `blkid` / `tune2fs -l`.
    private static func uuidString(from info: inout fs_ext4_volume_info_t) -> String {
        withUnsafePointer(to: info.uuid) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 16) { b in
                String(format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                       b[0],  b[1],  b[2],  b[3],
                       b[4],  b[5],
                       b[6],  b[7],
                       b[8],  b[9],
                       b[10], b[11], b[12], b[13], b[14], b[15])
            }
        }
    }

    /// Returns nil for empty strings — freshly mkfs'd volumes have no last-mount path,
    /// and surfacing an empty string confuses the host app's detail view.
    private static func lastMountedPath(from info: inout fs_ext4_volume_info_t) -> String? {
        withUnsafePointer(to: info.last_mounted) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 64) { cstr in
                let s = String(cString: cstr)
                return s.isEmpty ? nil : s
            }
        }
    }

    func shutdown() {
        state.withLock { handle in
            if let fs = handle.ptr {
                fs_ext4_umount(fs)
                handle.ptr = nil
            }
        }
    }

    func stat(path: String) -> BackendFileAttributes? {
        state.withLock { handle in
            guard let fs = handle.ptr else { return nil }

            var attr = fs_ext4_attr_t()
            let rc = fs_ext4_stat(fs, path, &attr)
            guard rc == 0 else { return nil }

            return BackendFileAttributes(
                fileID: UInt64(attr.inode),
                fileType: Self.convertFileType(attr.file_type),
                mode: attr.mode,
                uid: attr.uid,
                gid: attr.gid,
                size: attr.size,
                linkCount: attr.link_count,
                atime: attr.atime,
                mtime: attr.mtime,
                ctime: attr.ctime,
                crtime: attr.crtime
            )
        }
    }

    func readDirectory(path: String) -> [BackendDirectoryEntry]? {
        state.withLock { handle in
            guard let fs = handle.ptr else {
                backendLogger.error("readDirectory(\(path)): bridgeFS is nil")
                return nil
            }
            guard let iter = fs_ext4_dir_open(fs, path) else {
                backendLogger.error("readDirectory(\(path)): fs_ext4_dir_open returned nil")
                return nil
            }
            defer { fs_ext4_dir_close(iter) }
            let entries = Self.collectEntries(from: iter)
            backendLogger.debug("readDirectory(\(path)): returning \(entries.count) entries")
            return entries
        }
    }

    private static func collectEntries(from iter: OpaquePointer) -> [BackendDirectoryEntry] {
        var entries: [BackendDirectoryEntry] = []
        while let de = fs_ext4_dir_next(iter) {
            entries.append(convertDirEntry(de))
        }
        return entries
    }

    private static func convertDirEntry(_ de: UnsafePointer<fs_ext4_dirent_t>) -> BackendDirectoryEntry {
        let name = withUnsafePointer(to: de.pointee.name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        return BackendDirectoryEntry(
            fileID: UInt64(de.pointee.inode),
            fileType: convertFileType(fs_ext4_file_type_t(rawValue: UInt32(de.pointee.file_type))),
            name: name
        )
    }

    func readFile(path: String, offset: UInt64, length: UInt64,
                  buffer: UnsafeMutableRawPointer) -> Int64 {
        // Wrap the caller's buffer pointer so the @Sendable
        // `withLock` body can capture it without a strict-concurrency
        // warning. Caller owns the storage; the FFI call below
        // is synchronous so the wrapper's lifetime is bounded.
        let wrappedBuffer = UncheckedMutableBuffer(p: buffer)
        return state.withLock { handle in
            guard let fs = handle.ptr else { return Int64(-1) }
            return fs_ext4_read_file(fs, path, wrappedBuffer.p, offset, length)
        }
    }

    func readSymlink(path: String) -> String? {
        state.withLock { handle -> String? in
            guard let fs = handle.ptr else { return nil }

            var buf = [CChar](repeating: 0, count: 4096)
            let rc = fs_ext4_readlink(fs, path, &buf, buf.count)
            guard rc == 0 else { return nil }

            return String(cString: buf)
        }
    }

    // MARK: - Write path

    func createFile(path: String, mode: UInt16) -> Bool {
        state.withLock { handle in
            guard let fs = handle.ptr else { return false }
            return fs_ext4_create(fs, path, mode) != 0
        }
    }

    func writeFile(path: String, data: UnsafeRawPointer, length: UInt64) -> Int64 {
        let wrappedData = UncheckedConstBuffer(p: data)
        return state.withLock { handle in
            guard let fs = handle.ptr else { return Int64(-1) }
            return fs_ext4_write_file(fs, path, wrappedData.p, length)
        }
    }

    /// Positional streaming write — see `FileSystemBackend.pwrite` doc.
    /// Returned size is the new file size, not the bytes written; the
    /// volume layer translates that back to `data.count`.
    func pwrite(path: String, offset: UInt64,
                data: UnsafeRawPointer, length: UInt64) -> Int64 {
        let wrappedData = UncheckedConstBuffer(p: data)
        return state.withLock { handle in
            guard let fs = handle.ptr else { return Int64(-1) }
            return fs_ext4_pwrite(fs, path, wrappedData.p, length, offset)
        }
    }

    func unlink(path: String) -> Bool {
        state.withLock { handle in
            guard let fs = handle.ptr else { return false }
            return fs_ext4_unlink(fs, path) == 0
        }
    }

    func rename(src: String, dst: String) -> Bool {
        state.withLock { handle in
            guard let fs = handle.ptr else { return false }
            // Use the replace variant so an existing destination is
            // atomically overwritten (POSIX rename(2) semantics). The
            // plain fs_ext4_rename rejects an existing dst with EEXIST,
            // which breaks in-place editors (e.g. `sed -i`) that write a
            // temp file then rename it over the original.
            return fs_ext4_rename2(fs, src, dst, FS_EXT4_RENAME_REPLACE) == 0
        }
    }

    func mkdir(path: String, mode: UInt16) -> Bool {
        state.withLock { handle in
            guard let fs = handle.ptr else { return false }
            return fs_ext4_mkdir(fs, path, mode) != 0
        }
    }

    func rmdir(path: String) -> Bool {
        state.withLock { handle in
            guard let fs = handle.ptr else { return false }
            return fs_ext4_rmdir(fs, path) == 0
        }
    }

    func truncate(path: String, size: UInt64) -> Bool {
        state.withLock { handle in
            guard let fs = handle.ptr else { return false }
            return fs_ext4_truncate(fs, path, size) == 0
        }
    }

    func chmod(path: String, mode: UInt16) -> Bool {
        state.withLock { handle in
            guard let fs = handle.ptr else { return false }
            return fs_ext4_chmod(fs, path, mode) == 0
        }
    }

    func chown(path: String, uid: UInt32?, gid: UInt32?) -> Bool {
        state.withLock { handle in
            guard let fs = handle.ptr else { return false }
            let cuid = uid ?? ~UInt32(0)
            let cgid = gid ?? ~UInt32(0)
            return fs_ext4_chown(fs, path, cuid, cgid) == 0
        }
    }

    func symlink(target: String, linkpath: String) -> Bool {
        state.withLock { handle in
            guard let fs = handle.ptr else { return false }
            return fs_ext4_symlink(fs, target, linkpath) != 0
        }
    }

    func link(src: String, dst: String) -> Bool {
        state.withLock { handle in
            guard let fs = handle.ptr else { return false }
            return fs_ext4_link(fs, src, dst) == 0
        }
    }

    func utimens(path: String, atime: timespec?, mtime: timespec?) -> Bool {
        state.withLock { handle in
            guard let fs = handle.ptr else { return false }
            let aSec: UInt32 = atime.map { UInt32(clamping: $0.tv_sec) } ?? ~UInt32(0)
            let aNsec: UInt32 = atime.map { UInt32(clamping: $0.tv_nsec) } ?? 0
            let mSec: UInt32 = mtime.map { UInt32(clamping: $0.tv_sec) } ?? ~UInt32(0)
            let mNsec: UInt32 = mtime.map { UInt32(clamping: $0.tv_nsec) } ?? 0
            return fs_ext4_utimens(fs, path, aSec, aNsec, mSec, mNsec) == 0
        }
    }

    func flush() -> Bool {
        // The fs_ext4 driver currently has no top-level flush call — the
        // RW callback's flush handler is what gets called from inside the
        // driver. From Swift's side, returning success is correct: any
        // pending writes were already pushed via the callback during the
        // operation that produced them.
        return true
    }

    func lastErrno() -> Int32 {
        return Int32(fs_ext4_last_errno())
    }

    /// Run journal replay if the volume's on-disk journal is dirty. Idempotent
    /// — safe to call on a clean volume. Returns true on success (or
    /// already-clean), false on failure.
    func replayJournalIfDirty() -> Bool {
        state.withLock { handle in
            guard let fs = handle.ptr else { return false }
            return fs_ext4_replay_journal_if_dirty(fs) == 0
        }
    }

    // MARK: - fsck

    struct FsckReport {
        let inodesVisited: UInt64
        let directoriesScanned: UInt64
        let entriesScanned: UInt64
        /// **Authoritative current** anomaly count. After a repair
        /// pass this is the post-repair re-scan count — what's still
        /// actually wrong on disk. NOT initial-minus-repaired.
        let anomaliesFound: UInt64
        let wasDirty: Bool
        let dirtyCleared: Bool
        /// Number of anomalies the repair pass committed to disk. 0
        /// when the run was read-only.
        let repairedCount: UInt64
        /// Anomalies the audit found BEFORE any repair commits.
        /// Equal to `anomaliesFound` for non-repair runs. After a
        /// repair pass: `initialAnomaliesFound - repairedCount` is
        /// what we EXPECT to remain; `anomaliesFound` is what
        /// ACTUALLY remains. A discrepancy flags repair-logic bugs.
        let initialAnomaliesFound: UInt64

        /// Format the report as `fsck.done` event fields. Mirrors
        /// `NTFSVolume.FsckReport.toEventFields()` — both include
        /// `dirty_cleared` and `logfile_bytes` (set to "0" here since
        /// ext4 fsck doesn't touch a log file the way NTFS does) so
        /// the host app's `AttachedDisksModel.applyEventInPlace`
        /// consumes either with the same code path.
        func toEventFields() -> [String: String] {
            return [
                "dirty_cleared":           dirtyCleared ? "true" : "false",
                "logfile_bytes":           "0",
                "anomalies":               "\(anomaliesFound)",
                "directories":             "\(directoriesScanned)",
                "inodes":                  "\(inodesVisited)",
                "repaired_count":          "\(repairedCount)",
                "initial_anomalies_count": "\(initialAnomaliesFound)",
            ]
        }
    }

    struct FsckFinding {
        /// One of "link_count_low", "link_count_high", "dangling_entry",
        /// "wrong_dotdot", "bogus_entry", "duplicate_dir_inode"
        /// (Rust-emitted strings — do NOT extend without coordinating
        /// with the Rust crate's `anomaly_to_capi`).
        let kind: String
        let inode: UInt32
        let detail: String
    }

    /// Box for the two Swift closures fsck needs to call back into.
    /// Required because `@convention(c)` callbacks (which Rust expects)
    /// cannot capture Swift state — we pass `Unmanaged.passRetained(...)
    /// .toOpaque()` as the `context` and unwrap inside the C closure.
    /// Same pattern as `BlockDeviceContext` for the I/O callbacks.
    private final class FsckCallbackBox {
        let onProgress: (_ phase: String, _ done: UInt64, _ total: UInt64) -> Void
        let onFinding: (FsckFinding) -> Void
        init(onProgress: @escaping (_ phase: String, _ done: UInt64, _ total: UInt64) -> Void,
             onFinding: @escaping (FsckFinding) -> Void) {
            self.onProgress = onProgress
            self.onFinding = onFinding
        }
    }

    /// Run an fsck pass on the mounted volume.
    ///
    /// Default is read-only (audit + report only). Pass `repair: true`
    /// to commit journaled fixes for the anomaly classes the Rust
    /// crate's `audit_with_repair` knows how to handle (duplicate
    /// directory entries, link-count drift today; orphan / dangling /
    /// wrong-dotdot remain detect-only).
    ///
    /// `onProgress` and `onFinding` fire from the Rust thread that drives
    /// the scan — the caller is responsible for hopping to its own
    /// queue/actor before touching shared state.
    ///
    /// Holds the per-handle state lock for the whole scan. Because fsck
    /// is read-only and doesn't reenter the backend through other code
    /// paths, this is safe — no deadlock risk.
    func runFsck(
        repair: Bool = false,
        onProgress: @escaping (_ phase: String, _ done: UInt64, _ total: UInt64) -> Void,
        onFinding: @escaping (FsckFinding) -> Void
    ) -> Result<FsckReport, Error> {
        return state.withLock { handle -> Result<FsckReport, Error> in
            guard let fs = handle.ptr else {
                return .failure(POSIXError(.EBADF))
            }

            let box = FsckCallbackBox(onProgress: onProgress, onFinding: onFinding)
            let ctxPtr = Unmanaged.passRetained(box).toOpaque()
            defer { Unmanaged<FsckCallbackBox>.fromOpaque(ctxPtr).release() }

            var opts = fs_ext4_fsck_options_t()
            // Repair pass requires read_only = 0 so the journaled
            // commits inside `audit_with_repair` can land.
            opts.read_only = repair ? 0 : 1
            opts.repair = repair ? 1 : 0
            opts.replay_journal = 1
            opts.max_dirs = 0
            opts.max_entries_per_dir = 0
            opts.context = ctxPtr
            opts.on_progress = { ctx, _phase, phaseName, done, total in
                guard let ctx = ctx else { return }
                let box = Unmanaged<FsckCallbackBox>.fromOpaque(ctx).takeUnretainedValue()
                let name = phaseName.flatMap { String(cString: $0) } ?? ""
                box.onProgress(name, done, total)
            }
            opts.on_finding = { ctx, kind, inode, detail in
                guard let ctx = ctx else { return }
                let box = Unmanaged<FsckCallbackBox>.fromOpaque(ctx).takeUnretainedValue()
                let kindStr = kind.flatMap { String(cString: $0) } ?? ""
                let detailStr = detail.flatMap { String(cString: $0) } ?? ""
                box.onFinding(FsckFinding(kind: kindStr, inode: inode, detail: detailStr))
            }

            var report = fs_ext4_fsck_report_t()
            let rc = fs_ext4_fsck_run(fs, &opts, &report)
            if rc != 0 {
                let msg = fs_ext4_last_error().flatMap { String(cString: $0) } ?? "fs_ext4_fsck_run failed (rc=\(rc))"
                let err = NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(POSIXErrorCode.EIO.rawValue),
                    userInfo: [NSLocalizedDescriptionKey: msg]
                )
                return .failure(err)
            }

            return .success(FsckReport(
                inodesVisited: report.inodes_visited,
                directoriesScanned: report.directories_scanned,
                entriesScanned: report.entries_scanned,
                anomaliesFound: report.anomalies_found,
                wasDirty: report.was_dirty != 0,
                dirtyCleared: report.dirty_cleared != 0,
                repairedCount: report.repaired_count,
                initialAnomaliesFound: report.initial_anomalies_count
            ))
        }
    }

    /// Run an fsck pass that writes back fixes for anomalies it finds.
    /// Thin wrapper over `runFsck(repair: true, …)` — separate entry
    /// point so call sites that mean "repair" read clearly.
    func runRepair(
        onProgress: @escaping (_ phase: String, _ done: UInt64, _ total: UInt64) -> Void,
        onFinding: @escaping (FsckFinding) -> Void
    ) -> Result<FsckReport, Error> {
        runFsck(repair: true, onProgress: onProgress, onFinding: onFinding)
    }

    // MARK: - Helpers

    private static func convertFileType(_ bridgeType: fs_ext4_file_type_t) -> BackendFileType {
        switch bridgeType {
        case FS_EXT4_FT_REG_FILE: return .file
        case FS_EXT4_FT_DIR:      return .directory
        case FS_EXT4_FT_SYMLINK:  return .symlink
        case FS_EXT4_FT_CHRDEV:   return .charDevice
        case FS_EXT4_FT_BLKDEV:   return .blockDevice
        case FS_EXT4_FT_FIFO:     return .fifo
        case FS_EXT4_FT_SOCK:     return .socket
        default:                       return .unknown
        }
    }
}
