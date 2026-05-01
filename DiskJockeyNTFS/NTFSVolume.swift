/*
 * NTFSVolume.swift — FSKit volume implementation for NTFS.
 *
 * Implements FSVolume.Operations and FSVolume.ReadWriteOperations
 * for read-only access to NTFS filesystems.
 *
 * All operations use async/await (not replyHandler callbacks) to avoid
 * deadlocks on FSKit's internal serial queue.
 *
 * MIT License — see LICENSE
 */

import FSKit
import Foundation
import os

/// Represents a mounted NTFS volume.
/// All file operations are dispatched to the Rust bridge layer.
final class NTFSVolume: FSVolume,
                        FSVolume.Operations,
                        FSVolume.ReadWriteOperations,
                        FSVolume.PathConfOperations {

    /// Opaque pointer to the Rust bridge filesystem context
    private var bridgeFS: OpaquePointer?

    /// The block device resource
    private let blockDevice: FSBlockDeviceResource

    /// Retained block-device callback context (`NTFSBlockDeviceContext`).
    /// Held as an opaque pointer so the C callbacks in `cfg` can deref it
    /// the same way they do during the initial mount in
    /// `NTFSFileSystem.loadResource`. Lifetime is the volume's lifetime —
    /// freed in `deactivate`/`unmount`.
    private let contextPtr: UnsafeMutableRawPointer

    /// `cfg.size_bytes` captured at load time (block_count * block_size),
    /// reused when the volume rebuilds the cfg for fsck + RW remount.
    private let cfgSizeBytes: UInt64

    /// BSD device name (e.g. `disk5s1`). Carried so `activate`'s deferred
    /// fsck progress events tag the right disk in the host app's log strip.
    private let bsdName: String

    /// True when `loadResource` deferred the dirty-check / $LogFile reset
    /// because writes don't work during loadResource. The first
    /// `activate(options:)` call must unmount the RO handle, run fsck via
    /// callbacks, and remount RW. Mirror of EXT4's `requiresJournalReplay`.
    private var requiresFsckRemount: Bool

    /// Per-mount I/O counter aggregator. Owns the 1 Hz `io.stats`
    /// emitter that the host app's AttachedDisksModel ingests. Started
    /// in `NTFSFileSystem.loadResource`, stopped in `deactivate`.
    private let stats: IOStatsCollector

    /// Track items by file record number for reclamation
    private var items: [UInt64: NTFSItem] = [:]
    private let itemsLock = NSLock()

    init(volumeID: FSVolume.Identifier,
         volumeName: FSFileName,
         bridgeFS: OpaquePointer,
         blockDevice: FSBlockDeviceResource,
         contextPtr: UnsafeMutableRawPointer,
         cfgSizeBytes: UInt64,
         bsdName: String,
         requiresFsckRemount: Bool,
         stats: IOStatsCollector) {
        self.bridgeFS = bridgeFS
        self.blockDevice = blockDevice
        self.contextPtr = contextPtr
        self.cfgSizeBytes = cfgSizeBytes
        self.bsdName = bsdName
        self.requiresFsckRemount = requiresFsckRemount
        self.stats = stats
        super.init(volumeID: volumeID, volumeName: volumeName)
    }

    // MARK: - AppleDouble helpers

    /// Sentinel MFT record number used for ghost AppleDouble (`._*`) items
    /// we silently swallow. NTFS file record numbers are 64-bit; pick a
    /// value at the top of the 64-bit space, well outside any record
    /// number the NTFS driver would ever assign to a real file.
    private static let appleDoubleGhostRecord: UInt64 = 0xFFFF_FFFF_FFFF_FFFE

    /// Returns true if the basename starts with `._` — macOS Finder /
    /// Desktop Services AppleDouble metadata. We silently swallow
    /// creates and subsequent ops on these files: accept the operation
    /// (apps don't error) but never persist the bytes to disk.
    /// Justification: AppleDouble files only carry HFS-specific
    /// resource-fork / FinderInfo metadata that's irrelevant on
    /// NTFS volumes that round-trip back to Linux/Windows.
    private static func isAppleDouble(name: String) -> Bool {
        name.hasPrefix("._")
    }

    private static func basename(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? ""
    }

    private static func isAppleDouble(path: String) -> Bool {
        isAppleDouble(name: basename(of: path))
    }

    /// Synthesize `FSItem.Attributes` for a ghost AppleDouble item that
    /// only exists in our short-circuited code path. Type=file, size=0,
    /// mode=0o644, times=now, fileID=the ghost sentinel.
    private static func ghostAppleDoubleAttributes(for path: String) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.type = .file
        attrs.mode = 0o644
        attrs.size = 0
        attrs.allocSize = 0
        attrs.linkCount = 1
        let now = timespec(tv_sec: Int(time(nil)), tv_nsec: 0)
        attrs.accessTime = now
        attrs.modifyTime = now
        attrs.changeTime = now
        attrs.fileID = FSItem.Identifier(rawValue: appleDoubleGhostRecord)!
        return attrs
    }

    // MARK: - Item management

    private func item(forRecordNumber recno: UInt64, path: String) -> NTFSItem {
        itemsLock.lock()
        defer { itemsLock.unlock() }

        if let existing = items[recno] {
            return existing
        }

        let newItem = NTFSItem(fileRecordNumber: recno, path: path)
        items[recno] = newItem
        return newItem
    }

    // MARK: - Volume capabilities

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsPersistentObjectIDs = true
        caps.supportsSymbolicLinks = true
        caps.supportsHardLinks = true
        // NTFS keeps a $LogFile transactional journal; the Rust layer replays
        // / resets it on mount via fs_ntfs_fsck_with_callbacks.
        caps.supportsJournal = true
        caps.supportsActiveJournal = true
        // NTFS supports sparse files and very large files.
        caps.supportsSparseFiles = true
        caps.supports2TBFiles = true
        // MFT record numbers are 64-bit-wide on disk.
        caps.supports64BitObjectIDs = true
        // NTFS is case-preserving / case-insensitive by default.
        caps.caseFormat = .insensitiveCasePreserving
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        let stats = FSStatFSResult(fileSystemTypeName: "ntfs")

        guard let fs = bridgeFS else { return stats }

        var info = fs_ntfs_volume_info_t()
        fs_ntfs_get_volume_info(fs, &info)

        stats.blockSize = Int(info.cluster_size)
        stats.ioSize = Int(info.cluster_size)
        stats.totalBlocks = info.total_clusters
        stats.availableBlocks = 0
        stats.freeBlocks = 0
        stats.totalFiles = 0
        stats.freeFiles = 0

        return stats
    }

    // MARK: - Mount/unmount

    func mount(options: FSTaskOptions) async throws {
        log.info("volume: mount", scope: AppLogScope.lifecycle)
    }

    func unmount() async {
        log.info("volume: unmount", scope: AppLogScope.lifecycle)
        if let fs = bridgeFS {
            fs_ntfs_umount(fs)
            bridgeFS = nil
        }
    }

    // MARK: - Activate/Deactivate

    func activate(options: FSTaskOptions) async throws -> FSItem {
        log.info("volume: activate", scope: AppLogScope.lifecycle)
        if requiresFsckRemount {
            performDeferredFsckAndRwRemount()
            requiresFsckRemount = false
        }
        return item(forRecordNumber: 5, path: "/")
    }

    // MARK: - fsck

    /// Mirror of `EXT4Backend.FsckReport`. Common fields (`wasDirty`,
    /// `dirtyCleared`) are intentionally identically named so callers
    /// can render them with the same code path. `logfileBytes` is
    /// NTFS-specific (the number of bytes overwritten in `$LogFile`
    /// during recovery); ext4 sets the analogous field to 0.
    struct FsckReport {
        let wasDirty: Bool
        let dirtyCleared: Bool
        let logfileBytes: UInt64

        /// Format the report as `fsck.done` event fields. Mirrors
        /// `EXT4Backend.FsckReport.toEventFields()` — both include
        /// `dirty_cleared` and `logfile_bytes` so the host app's
        /// `AttachedDisksModel.applyEventInPlace` consumes either with
        /// the same code path.
        func toEventFields() -> [String: String] {
            return [
                "dirty_cleared": dirtyCleared ? "true" : "false",
                "logfile_bytes": "\(logfileBytes)",
            ]
        }
    }

    /// Mirror of `EXT4Backend.FsckFinding`. NTFS fsck has no
    /// per-finding callback (the rust crate only reports progress + a
    /// terminal logfile_bytes / dirty_cleared pair), so the `onFinding`
    /// closure is never invoked — kept for shape parity with EXT4 so
    /// `startCheck` looks identical across extensions.
    struct FsckFinding {
        let kind: String
        let inode: UInt32
        let detail: String
    }

    /// Run an fsck pass on the volume.
    ///
    /// Pure: emits no NDJSON events. The caller (e.g.
    /// `NTFSFileSystem.startCheck` or `performDeferredFsckAndRwRemount`)
    /// is responsible for emitting `fsck.start` / `fsck.progress` /
    /// `fsck.done` / `fsck.failed`. This split mirrors `EXT4Backend.runFsck`
    /// — both `runFsck` implementations are pure FFI wrappers that hand
    /// progress + (where applicable) findings to the caller.
    ///
    /// The unmount→dirty-check→fsck→remount lifecycle is non-negotiable:
    /// the rust crate refuses to call fsck against a mounted handle
    /// (it rewrites `$LogFile` + the dirty bit on the raw device, which
    /// would conflict with the in-memory view held by a live mount).
    /// Even on already-clean volumes we still do the cycle because we
    /// don't know the volume is clean until after the dirty check.
    ///
    /// `onProgress` fires from the rust crate's worker thread. After
    /// this method returns, `bridgeFS` is live again (RW preferred, RO
    /// fallback) so subsequent FSKit ops work. Concurrent reads/writes
    /// during the call will fail.
    func runFsck(
        onProgress: @escaping (_ phase: String, _ done: UInt64, _ total: UInt64) -> Void,
        onFinding: @escaping (FsckFinding) -> Void
    ) -> Result<FsckReport, Error> {
        _ = onFinding  // NTFS has no per-finding callback; param is for shape parity with EXT4.

        // Drop any current handle before fsck. Safe to call when
        // bridgeFS is already nil — we just skip the umount.
        if let oldFs = bridgeFS {
            fs_ntfs_umount(oldFs)
            bridgeFS = nil
        }

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
        cfg.size_bytes = cfgSizeBytes

        // Always remount before returning — even on errors — so the
        // volume stays usable. Captured here so every exit path runs it.
        func remount() {
            if let newFs = fs_ntfs_mount_with_callbacks(&cfg) {
                bridgeFS = newFs
            } else {
                cfg.write = nil
                bridgeFS = fs_ntfs_mount_with_callbacks(&cfg)
            }
        }

        let dirtyResult = fs_ntfs_is_dirty_with_callbacks(&cfg)
        switch dirtyResult {
        case 1:
            // Dirty — actually run fsck.
            let box = FsckProgressBox(onProgress: onProgress)
            let boxPtr = Unmanaged.passRetained(box).toOpaque()
            defer { Unmanaged<FsckProgressBox>.fromOpaque(boxPtr).release() }

            var logfileBytes: UInt64 = 0
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
                &logfileBytes,
                &dirtyCleared
            )
            remount()
            if rc == 0 {
                return .success(FsckReport(
                    wasDirty: true,
                    dirtyCleared: dirtyCleared == 1,
                    logfileBytes: logfileBytes
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
            return .success(FsckReport(wasDirty: false, dirtyCleared: false, logfileBytes: 0))

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

    /// Lazy-activation entry point. Calls `runFsck` and emits the
    /// lifecycle-scoped `volume.dirty` / `volume.clean` + fsck.* events
    /// the host app's `AttachedDisksModel` consumes. Distinct from
    /// startCheck's emissions in scope (`lifecycle` vs `fsck`) but
    /// identical in shape.
    private func performDeferredFsckAndRwRemount() {
        let dlog = TaggedLogger(log, fields: ["bsd": bsdName], kind: "ntfs.activate",
                                scope: AppLogScope.lifecycle)
        dlog.info("performing deferred fsck + RW remount")

        let result = runFsck(
            onProgress: { phase, done, total in
                log.event(kind: "fsck.progress", fields: [
                    "bsd": self.bsdName,
                    "phase": phase,
                    "done": "\(done)",
                    "total": "\(total)",
                ], scope: AppLogScope.fsck)
            },
            onFinding: { _ in /* unused on NTFS */ }
        )

        switch result {
        case .success(let report) where report.wasDirty:
            dlog.event(kind: "volume.dirty", scope: AppLogScope.volume)
            // The fsck.start/done pair only fires when work was actually
            // done. Synthesise a start now for symmetry with the explicit
            // path; emission order matches the explicit path too.
            dlog.event(kind: "fsck.start", scope: AppLogScope.fsck)
            dlog.event(kind: "fsck.done", fields: report.toEventFields(),
                       scope: AppLogScope.fsck)
        case .success(let report):
            // Clean — emit only the volume.clean signal. Skipping
            // fsck.start/done keeps the deferred path quiet on already-
            // clean mounts (matches pre-unification behaviour).
            _ = report
            dlog.event(kind: "volume.clean", scope: AppLogScope.volume)
        case .failure(let err):
            dlog.event(kind: "fsck.failed", fields: ["error": "\(err.localizedDescription)"],
                       level: .error, scope: AppLogScope.fsck)
        }
    }

    func deactivate(options: FSDeactivateOptions) async throws {
        log.info("volume: deactivate", scope: AppLogScope.lifecycle)
        // Stop the stats heartbeat first so the final tally lands while
        // the AppLog sinks are still alive.
        stats.stop()
        if let fs = bridgeFS {
            fs_ntfs_umount(fs)
            bridgeFS = nil
        }
    }

    // MARK: - File attributes

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

    func attributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem
    ) async throws -> FSItem.Attributes {
        guard let fs = bridgeFS, let ntfsItem = item as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }

        // Ghost AppleDouble — return synthetic attrs without hitting bridge.
        if Self.isAppleDouble(path: ntfsItem.path) {
            return Self.ghostAppleDoubleAttributes(for: ntfsItem.path)
        }

        var attr = fs_ntfs_attr_t()
        let rc = fs_ntfs_stat(fs, ntfsItem.path, &attr)
        guard rc == 0 else {
            throw fs_errorForPOSIXError(ENOENT)
        }

        let attrs = FSItem.Attributes()
        attrs.type = Self.fsItemType(from: attr.file_type)
        attrs.mode = UInt32(attr.mode)
        attrs.uid = 0
        attrs.gid = 0
        attrs.size = attr.size
        attrs.linkCount = UInt32(attr.link_count)
        attrs.allocSize = attr.size

        attrs.accessTime = timespec(tv_sec: Int(attr.atime), tv_nsec: 0)
        attrs.modifyTime = timespec(tv_sec: Int(attr.mtime), tv_nsec: 0)
        attrs.changeTime = timespec(tv_sec: Int(attr.ctime), tv_nsec: 0)

        if attr.crtime > 0 {
            attrs.addedTime = timespec(tv_sec: Int(attr.crtime), tv_nsec: 0)
        }

        attrs.fileID = FSItem.Identifier(rawValue: attr.file_record_number)!

        return attrs
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem
    ) async throws -> FSItem.Attributes {
        guard let fs = bridgeFS, let ntfsItem = item as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }

        // Ghost AppleDouble — pretend every attribute was applied,
        // return synthetic state. Nothing hits the bridge.
        if Self.isAppleDouble(path: ntfsItem.path) {
            newAttributes.consumedAttributes = [
                .mode, .uid, .gid,
                .accessTime, .modifyTime, .changeTime, .addedTime,
                .size,
            ]
            return Self.ghostAppleDoubleAttributes(for: ntfsItem.path)
        }

        var consumed: FSItem.Attribute = []

        // NTFS uses ACLs / SIDs rather than POSIX mode/uid/gid bits. We accept
        // the request silently — marking the attribute as consumed so FSKit
        // stops retrying — without translating it to an NTFS-side change.
        // Throwing ENOTSUP here breaks macOS Finder copy/save flows that
        // routinely set permission bits.
        if newAttributes.isValid(.mode) {
            consumed.insert(.mode)
        }
        if newAttributes.isValid(.uid) {
            consumed.insert(.uid)
        }
        if newAttributes.isValid(.gid) {
            consumed.insert(.gid)
        }

        // Truncate (shrink-only in W2 MVP).
        if newAttributes.isValid(.size) {
            let newSize = newAttributes.size
            var current = fs_ntfs_attr_t()
            guard fs_ntfs_stat(fs, ntfsItem.path, &current) == 0 else {
                throw fs_errorForPOSIXError(ENOENT)
            }
            if newSize > current.size {
                // Grow not supported by fs_ntfs_truncate_h yet.
                throw fs_errorForPOSIXError(ENOTSUP)
            }
            let rc = fs_ntfs_truncate_h(fs, ntfsItem.path, newSize)
            if rc < 0 {
                let err = Int32(fs_ntfs_last_errno())
                throw fs_errorForPOSIXError(err != 0 ? err : EIO)
            }
            consumed.insert(.size)
        }

        // Times: convert UNIX timespecs to NTFS FILETIME (100ns ticks
        // since 1601-01-01 UTC). Pass NULL for any time we aren't
        // touching.
        let creationValid = newAttributes.isValid(.addedTime)
        let modifyValid = newAttributes.isValid(.modifyTime)
        let changeValid = newAttributes.isValid(.changeTime)
        let accessValid = newAttributes.isValid(.accessTime)

        if creationValid || modifyValid || changeValid || accessValid {
            var creation: Int64 = 0
            var modify: Int64 = 0
            var change: Int64 = 0
            var access: Int64 = 0
            if creationValid { creation = Self.filetimeFromTimespec(newAttributes.addedTime) }
            if modifyValid { modify = Self.filetimeFromTimespec(newAttributes.modifyTime) }
            if changeValid { change = Self.filetimeFromTimespec(newAttributes.changeTime) }
            if accessValid { access = Self.filetimeFromTimespec(newAttributes.accessTime) }

            let rc: Int32 = withUnsafePointer(to: &creation) { cPtr in
                withUnsafePointer(to: &modify) { mPtr in
                    withUnsafePointer(to: &change) { chPtr in
                        withUnsafePointer(to: &access) { aPtr in
                            fs_ntfs_set_times_h(
                                fs,
                                ntfsItem.path,
                                creationValid ? cPtr : nil,
                                modifyValid ? mPtr : nil,
                                changeValid ? chPtr : nil,
                                accessValid ? aPtr : nil
                            )
                        }
                    }
                }
            }
            if rc != 0 {
                let err = Int32(fs_ntfs_last_errno())
                throw fs_errorForPOSIXError(err != 0 ? err : EIO)
            }
            if creationValid { consumed.insert(.addedTime) }
            if modifyValid { consumed.insert(.modifyTime) }
            if changeValid { consumed.insert(.changeTime) }
            if accessValid { consumed.insert(.accessTime) }
        }

        newAttributes.consumedAttributes = consumed

        // Re-stat to return the post-mutation attributes.
        var attr = fs_ntfs_attr_t()
        guard fs_ntfs_stat(fs, ntfsItem.path, &attr) == 0 else {
            throw fs_errorForPOSIXError(ENOENT)
        }
        return Self.attributes(from: attr)
    }

    // MARK: - Lookup

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> (FSItem, FSFileName) {
        guard let fs = bridgeFS, let dirItem = directory as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }

        guard let nameStr = name.string else {
            throw fs_errorForPOSIXError(EINVAL)
        }

        let childPath = dirItem.path == "/" ? "/\(nameStr)" : "\(dirItem.path)/\(nameStr)"

        var attr = fs_ntfs_attr_t()
        let rc = fs_ntfs_stat(fs, childPath, &attr)
        guard rc == 0 else {
            throw fs_errorForPOSIXError(ENOENT)
        }

        let foundItem = item(forRecordNumber: attr.file_record_number, path: childPath)
        return (foundItem, name)
    }

    // MARK: - Directory enumeration

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker
    ) async throws -> FSDirectoryVerifier {
        guard let fs = bridgeFS, let dirItem = directory as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }

        guard let iter = fs_ntfs_dir_open(fs, dirItem.path) else {
            throw fs_errorForPOSIXError(EIO)
        }
        defer { fs_ntfs_dir_close(iter) }

        var entryCookie: UInt64 = 1
        let startCookie = cookie.rawValue

        while let de = fs_ntfs_dir_next(iter) {
            if entryCookie <= startCookie {
                entryCookie += 1
                continue
            }

            let entryName = withUnsafePointer(to: de.pointee.name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 256) { cstr in
                    String(cString: cstr)
                }
            }

            let fsName = FSFileName(string: entryName)
            let childPath = dirItem.path == "/" ? "/\(entryName)" : "\(dirItem.path)/\(entryName)"
            let fileType = Self.fsItemType(fromRaw: de.pointee.file_type)

            var itemAttrs: FSItem.Attributes? = nil
            if attributes != nil {
                var attr = fs_ntfs_attr_t()
                if fs_ntfs_stat(fs, childPath, &attr) == 0 {
                    itemAttrs = FSItem.Attributes()
                    itemAttrs?.type = Self.fsItemType(from: attr.file_type)
                    itemAttrs?.mode = UInt32(attr.mode)
                    itemAttrs?.uid = 0
                    itemAttrs?.gid = 0
                    itemAttrs?.size = attr.size
                    itemAttrs?.linkCount = UInt32(attr.link_count)
                    itemAttrs?.fileID = FSItem.Identifier(rawValue: attr.file_record_number)!
                }
            }

            let packed = packer.packEntry(
                name: fsName,
                itemType: fileType,
                itemID: FSItem.Identifier(rawValue: de.pointee.file_record_number)!,
                nextCookie: FSDirectoryCookie(rawValue: entryCookie),
                attributes: itemAttrs
            )

            if !packed { break }
            entryCookie += 1
        }

        return FSDirectoryVerifier(rawValue: entryCookie)
    }

    // MARK: - Reclaim

    func reclaimItem(_ item: FSItem) async throws {
        if let ntfsItem = item as? NTFSItem {
            itemsLock.lock()
            items.removeValue(forKey: ntfsItem.fileRecordNumber)
            itemsLock.unlock()
        }
    }

    // MARK: - Symlink

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        guard let fs = bridgeFS, let ntfsItem = item as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }

        var buf = [CChar](repeating: 0, count: 4096)
        let rc = fs_ntfs_readlink(fs, ntfsItem.path, &buf, buf.count)
        guard rc == 0 else {
            throw fs_errorForPOSIXError(EIO)
        }

        return FSFileName(string: String(cString: buf))
    }

    // MARK: - Mutating ops

    func createItem(
        named name: FSFileName, type: FSItem.ItemType,
        inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest
    ) async throws -> (FSItem, FSFileName) {
        guard let fs = bridgeFS, let dirItem = directory as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }
        guard let nameStr = name.string else {
            throw fs_errorForPOSIXError(EINVAL)
        }
        let childPath = Self.joinPath(dirItem.path, nameStr)

        // AppleDouble (`._foo`) — silently swallow create. Returns a
        // ghost FSItem whose subsequent write/read/attr/remove ops are
        // handled inline below. We never touch the underlying NTFS
        // filesystem for these names. Same approach Tuxera/ntfs-3g use.
        if Self.isAppleDouble(name: nameStr) {
            log.info("createItem: silently swallowing AppleDouble \(childPath)", scope: AppLogScope.enumerate)
            let ghost = item(forRecordNumber: Self.appleDoubleGhostRecord, path: childPath)
            attributes.consumedAttributes = [.mode, .uid, .gid, .accessTime, .modifyTime]
            return (ghost, name)
        }

        let mftNum: Int64
        switch type {
        case .file:
            mftNum = fs_ntfs_create_file_h(fs, dirItem.path, nameStr)
        case .directory:
            mftNum = fs_ntfs_mkdir_h(fs, dirItem.path, nameStr)
        case .symlink:
            // TODO: needs fs_ntfs_create_symlink_h — the path-based
            // fs_ntfs_create_symlink can't be used through a callback-
            // mounted handle, so we can't honour symlink creation here.
            throw fs_errorForPOSIXError(ENOTSUP)
        default:
            throw fs_errorForPOSIXError(ENOTSUP)
        }

        if mftNum < 0 {
            let err = Int32(fs_ntfs_last_errno())
            throw fs_errorForPOSIXError(err != 0 ? err : EIO)
        }

        let newItem = item(forRecordNumber: UInt64(mftNum), path: childPath)

        // Best-effort: apply any caller-supplied attributes. If this
        // fails, log and proceed — the file/dir was created successfully
        // and undoing the create would be the wrong call.
        do {
            _ = try await setAttributes(attributes, on: newItem)
        } catch {
            log.warn("createItem: setAttributes follow-up failed for \(childPath): \(error.localizedDescription)", scope: AppLogScope.enumerate)
        }

        return (newItem, name)
    }

    func createSymbolicLink(
        named name: FSFileName, inDirectory directory: FSItem,
        attributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName
    ) async throws -> (FSItem, FSFileName) {
        // TODO: needs fs_ntfs_create_symlink_h — only the path-based
        // fs_ntfs_create_symlink exists, which re-mounts the device and
        // can't be used through the FSKit callback bridge.
        throw fs_errorForPOSIXError(ENOTSUP)
    }

    func createLink(
        to item: FSItem, named name: FSFileName, inDirectory directory: FSItem
    ) async throws -> FSFileName {
        // TODO: handle-based hard link creation isn't exposed by the
        // fs_ntfs C ABI yet (path-based fs_ntfs_link only).
        throw fs_errorForPOSIXError(ENOTSUP)
    }

    func removeItem(
        _ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem
    ) async throws {
        guard let fs = bridgeFS, let ntfsItem = item as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }

        // Ghost AppleDouble — never existed on disk, succeed silently.
        if let nameStr = name.string, Self.isAppleDouble(name: nameStr) {
            return
        }

        var attr = fs_ntfs_attr_t()
        guard fs_ntfs_stat(fs, ntfsItem.path, &attr) == 0 else {
            throw fs_errorForPOSIXError(ENOENT)
        }

        let rc: Int32
        switch attr.file_type {
        case FS_NTFS_FT_DIR, FS_NTFS_FT_JUNCTION:
            rc = fs_ntfs_rmdir_h(fs, ntfsItem.path)
        case FS_NTFS_FT_REG_FILE, FS_NTFS_FT_SYMLINK:
            rc = fs_ntfs_unlink_h(fs, ntfsItem.path)
        default:
            throw fs_errorForPOSIXError(ENOTSUP)
        }

        if rc != 0 {
            let err = Int32(fs_ntfs_last_errno())
            throw fs_errorForPOSIXError(err != 0 ? err : EIO)
        }
    }

    func renameItem(
        _ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
        to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?
    ) async throws -> FSFileName {
        guard let fs = bridgeFS,
              let srcDir = sourceDirectory as? NTFSItem,
              let dstDir = destinationDirectory as? NTFSItem,
              let ntfsItem = item as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }
        guard let dstNameStr = destinationName.string else {
            throw fs_errorForPOSIXError(EINVAL)
        }

        // TODO: cross-directory rename needs follow-up Rust support —
        // fs_ntfs_rename_h takes a NEW BASENAME only.
        if srcDir !== dstDir && srcDir.path != dstDir.path {
            throw fs_errorForPOSIXError(ENOTSUP)
        }

        // If the destination already exists, remove it first. NTFS rename
        // semantics on collision aren't documented in the C ABI; the
        // safest portable behavior is to clear the way for the rename.
        if let over = overItem as? NTFSItem {
            var overAttr = fs_ntfs_attr_t()
            if fs_ntfs_stat(fs, over.path, &overAttr) == 0 {
                let removeRc: Int32
                switch overAttr.file_type {
                case FS_NTFS_FT_DIR, FS_NTFS_FT_JUNCTION:
                    removeRc = fs_ntfs_rmdir_h(fs, over.path)
                default:
                    removeRc = fs_ntfs_unlink_h(fs, over.path)
                }
                if removeRc != 0 {
                    let err = Int32(fs_ntfs_last_errno())
                    throw fs_errorForPOSIXError(err != 0 ? err : EIO)
                }
            }
        }

        let rc = fs_ntfs_rename_h(fs, ntfsItem.path, dstNameStr)
        if rc != 0 {
            let err = Int32(fs_ntfs_last_errno())
            throw fs_errorForPOSIXError(err != 0 ? err : EIO)
        }

        return destinationName
    }

    // MARK: - Sync

    func synchronize(flags: FSSyncFlags) async throws {
        // FSBlockDeviceResource does its own batching; no handle-level flush available.
    }

    // MARK: - ReadWriteOperations

    func read(
        from item: FSItem, at offset: off_t, length: Int,
        into buffer: FSMutableFileDataBuffer
    ) async throws -> Int {
        let t0 = monotonicNanos()
        do {
            let n = try await readImpl(from: item, at: offset, length: length, into: buffer)
            stats.recordRead(bytes: n, latencyNs: monotonicNanos() &- t0, error: false)
            return n
        } catch {
            stats.recordRead(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
            throw error
        }
    }

    private func readImpl(
        from item: FSItem, at offset: off_t, length: Int,
        into buffer: FSMutableFileDataBuffer
    ) async throws -> Int {
        guard let fs = bridgeFS, let ntfsItem = item as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }

        // Ghost AppleDouble — files are always empty, return 0 (EOF).
        if Self.isAppleDouble(path: ntfsItem.path) {
            return 0
        }

        return buffer.withUnsafeMutableBytes { rawBuf in
            let bytesRead = fs_ntfs_read_file(
                fs, ntfsItem.path, rawBuf.baseAddress,
                UInt64(offset), UInt64(length)
            )
            return max(0, Int(bytesRead))
        }
    }

    func write(
        contents data: Data, to item: FSItem, at offset: off_t
    ) async throws -> Int {
        let t0 = monotonicNanos()
        do {
            let n = try await writeImpl(contents: data, to: item, at: offset)
            stats.recordWrite(bytes: n, latencyNs: monotonicNanos() &- t0, error: false)
            return n
        } catch {
            stats.recordWrite(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
            throw error
        }
    }

    private func writeImpl(
        contents data: Data, to item: FSItem, at offset: off_t
    ) async throws -> Int {
        guard let fs = bridgeFS, let ntfsItem = item as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }

        // Ghost AppleDouble — accept the bytes, write nowhere.
        if Self.isAppleDouble(path: ntfsItem.path) {
            return data.count
        }

        // IMPORTANT: fs_ntfs_write_file_contents_h replaces the WHOLE
        // file. To emulate offset/partial writes we read-modify-write —
        // stat the current size, build a buffer of
        // max(currentSize, offset + data.count), splice the new bytes
        // in at `offset`, then call write_file_contents with the merged
        // buffer. This is O(filesize) per write — slow but correct.
        // TODO: replace with streaming write API when fs_ntfs exposes it.

        var attr = fs_ntfs_attr_t()
        guard fs_ntfs_stat(fs, ntfsItem.path, &attr) == 0 else {
            throw fs_errorForPOSIXError(ENOENT)
        }

        let currentSize = attr.size
        let writeOffset = UInt64(offset)
        let writeLen = UInt64(data.count)
        let newEnd = writeOffset + writeLen

        // Fast path: writing from offset 0 fully replaces or extends
        // the file. Skip the read-modify-write step.
        if writeOffset == 0 && writeLen >= currentSize {
            let written: Int64 = data.withUnsafeBytes { rawBuf -> Int64 in
                guard let base = rawBuf.baseAddress else { return -1 }
                return fs_ntfs_write_file_contents_h(fs, ntfsItem.path, base, writeLen)
            }
            if written < 0 {
                let err = Int32(fs_ntfs_last_errno())
                throw fs_errorForPOSIXError(err != 0 ? err : EIO)
            }
            return data.count
        }

        // Slow path: read-modify-write.
        let mergedSize = max(currentSize, newEnd)
        let bufferSize = Int(mergedSize)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buf.deallocate() }
        memset(buf, 0, bufferSize)

        if currentSize > 0 {
            let read = fs_ntfs_read_file(fs, ntfsItem.path, buf, 0, currentSize)
            if read < 0 || UInt64(read) < currentSize {
                let err = Int32(fs_ntfs_last_errno())
                throw fs_errorForPOSIXError(err != 0 ? err : EIO)
            }
        }

        data.withUnsafeBytes { rawBuf in
            if let base = rawBuf.baseAddress, !rawBuf.isEmpty {
                memcpy(buf.advanced(by: Int(writeOffset)), base, data.count)
            }
        }

        let written = fs_ntfs_write_file_contents_h(fs, ntfsItem.path, buf, mergedSize)
        if written < 0 {
            let err = Int32(fs_ntfs_last_errno())
            throw fs_errorForPOSIXError(err != 0 ? err : EIO)
        }
        return data.count
    }

    // MARK: - PathConfOperations

    var maximumLinkCount: Int { 1024 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }

    // MARK: - Helpers

    static func fsItemType(from bridgeType: fs_ntfs_file_type_t) -> FSItem.ItemType {
        switch bridgeType {
        case FS_NTFS_FT_REG_FILE: return .file
        case FS_NTFS_FT_DIR:      return .directory
        case FS_NTFS_FT_SYMLINK:  return .symlink
        default:                       return .file
        }
    }

    static func fsItemType(fromRaw rawType: UInt8) -> FSItem.ItemType {
        return fsItemType(from: fs_ntfs_file_type_t(rawValue: UInt32(rawType)))
    }

    /// Join a parent directory path to a child name, taking care to avoid
    /// the double-slash "//foo" trap when the parent is the root.
    static func joinPath(_ parent: String, _ child: String) -> String {
        return parent == "/" ? "/\(child)" : "\(parent)/\(child)"
    }

    /// Build an `FSItem.Attributes` snapshot from an fs_ntfs_attr_t. Used
    /// by `setAttributes` to return the post-mutation state without
    /// duplicating field-by-field plumbing.
    static func attributes(from attr: fs_ntfs_attr_t) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.type = fsItemType(from: attr.file_type)
        attrs.mode = UInt32(attr.mode)
        attrs.uid = 0
        attrs.gid = 0
        attrs.size = attr.size
        attrs.linkCount = UInt32(attr.link_count)
        attrs.allocSize = attr.size
        attrs.accessTime = timespec(tv_sec: Int(attr.atime), tv_nsec: 0)
        attrs.modifyTime = timespec(tv_sec: Int(attr.mtime), tv_nsec: 0)
        attrs.changeTime = timespec(tv_sec: Int(attr.ctime), tv_nsec: 0)
        if attr.crtime > 0 {
            attrs.addedTime = timespec(tv_sec: Int(attr.crtime), tv_nsec: 0)
        }
        if let id = FSItem.Identifier(rawValue: attr.file_record_number) {
            attrs.fileID = id
        }
        return attrs
    }

    /// Convert a UNIX timespec into an NTFS FILETIME (100ns ticks since
    /// 1601-01-01 UTC).
    /// `filetime = (unix_seconds + 11644473600) * 10_000_000 + nsec / 100`
    static func filetimeFromTimespec(_ ts: timespec) -> Int64 {
        let unixToFiletimeOffset: Int64 = 11_644_473_600
        let secs = Int64(ts.tv_sec) + unixToFiletimeOffset
        return secs * 10_000_000 + Int64(ts.tv_nsec) / 100
    }
}
