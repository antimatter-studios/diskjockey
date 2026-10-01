/*
 * NTFSVolume.swift — FSKit volume implementation for NTFS.
 *
 * Implements FSVolume.Operations and FSVolume.ReadWriteOperations
 * for read-write access to NTFS filesystems, over an NTFSBackend.
 *
 * All operations use async/await (not replyHandler callbacks) to avoid
 * deadlocks on FSKit's internal serial queue.
 *
 * MIT License — see LICENSE
 */

import FSKit
import Foundation
import os
import DiskJockeyLibrary

/// Represents a mounted NTFS volume.
/// Every driver call goes through `backend` — `NTFSDriver` in the
/// extension, a stand-in under `swift test` — so this file makes no C
/// call and builds as DiskJockeyNTFSCore (diskjockey#196).
final class NTFSVolume: FSVolume,
                        FSVolume.Operations,
                        FSVolume.ReadWriteOperations,
                        FSVolume.PathConfOperations {

    /// The driver, and the mount handle it owns.
    private let backend: NTFSBackend

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

    /// Per-volume `fileID → NTFSItem` cache. Get-or-create-or-replace
    /// semantics live in `FileIDCache`; the per-NTFS validation rule
    /// (path + parentRecordNumber must still match) is the closure
    /// passed from `item(forRecordNumber:)`.
    private let items = FileIDCache<NTFSItem>()

    init(volumeID: FSVolume.Identifier,
         volumeName: FSFileName,
         backend: NTFSBackend,
         bsdName: String,
         requiresFsckRemount: Bool,
         stats: IOStatsCollector) {
        self.backend = backend
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
    /// Standard read/write/execute mode for the ghost: owner rw, group r, other r.
    private static let appleDoubleGhostMode: UInt32 = 0o644

    // NTFS FILE_ATTRIBUTE_* flags used to drive Finder visibility.
    private static let ntfsAttrHidden: UInt32  = 0x0002 // FILE_ATTRIBUTE_HIDDEN
    private static let ntfsAttrSystem: UInt32  = 0x0004 // FILE_ATTRIBUTE_SYSTEM
    // UF_HIDDEN in BSD stat flags — tells Finder to suppress the item.
    private static let bsdFlagHidden:  UInt32  = 0x8000 // UF_HIDDEN

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

    /// Synthesize `FSItem.Attributes` for a ghost AppleDouble item.
    /// Same standard-set coverage as `attributes(from:parentRecordNumber:)`
    /// — flags, parentID, birthTime must all be set or FSKit rejects
    /// the reply with errno 2 (ENOENT) and the file appears to vanish.
    private static func ghostAppleDoubleAttributes(
        for path: String,
        parentRecordNumber: UInt64?
    ) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.type = .file
        attrs.mode = Self.appleDoubleGhostMode
        attrs.flags = 0
        attrs.size = 0
        attrs.allocSize = 0
        attrs.linkCount = 1
        let now = timespec(tv_sec: Int(time(nil)), tv_nsec: 0)
        attrs.accessTime = now
        attrs.modifyTime = now
        attrs.changeTime = now
        attrs.birthTime = now
        attrs.fileID = FSItem.Identifier(rawValue: appleDoubleGhostRecord)!
        let parentRaw = parentRecordNumber ?? 1
        if let parentID = FSItem.Identifier(rawValue: parentRaw) {
            attrs.parentID = parentID
        }
        return attrs
    }

    // MARK: - Item management

    /// Look up or create the cached `NTFSItem` for a given MFT record.
    ///
    /// On a hit, the cached item's `path` and `parentRecordNumber` are
    /// compared against the lookup context — if either differs, the
    /// cached entry is **replaced** rather than returned as-is.
    /// Mirror of the EXT4 cache fix; same rationale: every backend op
    /// is path-based, so returning an NTFSItem whose `path` doesn't
    /// match the kernel's current lookup leads to spurious ENOENT and
    /// (in the worst case) Finder rendering rename UI on the wrong
    /// dirent because two FSItems share an `FSItem.Identifier`.
    /// `parentRecordNumber` is `nil` only for the root directory — its
    /// parent is `FSItemIDParentOfRoot` (1).
    func item(forRecordNumber recno: UInt64, path: String,
              parentRecordNumber: UInt64?) -> NTFSItem {
        items.getOrCreate(
            id: recno,
            validate: { $0.path == path
                && $0.parentRecordNumber == parentRecordNumber },
            create: { NTFSItem(fileRecordNumber: recno, path: path,
                               parentRecordNumber: parentRecordNumber) }
        )
    }

    /// How the driver reads a path. Permanently UTF-8, unlike the Linux
    /// formats: an NTFS name is UTF-16 on disk, so every name it can hold
    /// has a UTF-8 spelling, and am-fs-ntfs decodes paths as UTF-8
    /// (diskjockey#219).
    static let pathEncoding: DriverPathEncoding = .utf8

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

        guard let info = backend.volumeInfo() else { return stats }

        stats.blockSize = Int(info.clusterSize)
        stats.ioSize = Int(info.clusterSize)
        stats.totalBlocks = info.totalClusters
        // TODO: `fs_ntfs_volume_info_t` doesn't expose `free_clusters`, so
        // we can't populate free / available space without extending the
        // rust FFI (touches vendor/rust-fs-ntfs). Until then, Finder's
        // "Get Info" pane and our detail view show "Free size: 0 B" for
        // NTFS volumes — known wrong, not "actually full".
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
        backend.unmount()
    }

    // MARK: - Activate/Deactivate

    func activate(options: FSTaskOptions) async throws -> FSItem {
        log.info("volume: activate", scope: AppLogScope.lifecycle)
        return activatedRoot()
    }

    /// The body of `activate`, which a test can call without an
    /// FSTaskOptions (FSKit's cannot be constructed).
    func activatedRoot() -> NTFSItem {
        if requiresFsckRemount {
            // Container-backed OR partition-sliced volumes use the fs_core
            // device chain for the deferred RW remount. Plain whole-disk
            // raw NTFS images use the historical callback-based path.
            if backend.remountsThroughDeviceChain {
                backend.remountReadWriteThroughDeviceChain()
            } else {
                performDeferredFsckAndRwRemount()
            }
            requiresFsckRemount = false
        }
        return item(forRecordNumber: 5, path: "/", parentRecordNumber: nil)
    }

    // MARK: - fsck

    /// Mirror of `EXT4Backend.FsckReport`. Common fields (`wasDirty`,
    /// `dirtyCleared`) are intentionally identically named so callers
    /// can render them with the same code path. `logfileBytes` is
    /// NTFS-specific (the number of bytes overwritten in `$LogFile`
    /// during recovery); ext4 sets the analogous field to 0.
    struct FsckReport: Equatable {
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
    /// The backend unmounts, checks, and remounts (RW preferred, RO
    /// fallback) on every path, so subsequent FSKit ops work. Concurrent
    /// reads/writes during the call will fail.
    func runFsck(
        onProgress: @escaping (_ phase: String, _ done: UInt64, _ total: UInt64) -> Void,
        onFinding: @escaping (FsckFinding) -> Void
    ) -> Result<FsckReport, Error> {
        _ = onFinding  // NTFS has no per-finding callback; param is for shape parity with EXT4.
        return backend.fsck(onProgress: onProgress)
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

        // Throttle fsck.progress emission. See EXT4FileSystem.startCheck
        // for rationale — Rust's onProgress fires once per record on a
        // multi-thousand-record volume, and each emit ends up on the
        // host's main actor.
        let appGroupDefaults = UserDefaults(suiteName: AppLog.groupIdentifier)
        let verbose = appGroupDefaults?.bool(forKey: "verboseRepairLog") ?? false
        let minIntervalNs: UInt64 = verbose ? 100_000_000 : 1_000_000_000
        var lastEmitMonotonic: UInt64 = 0
        var lastPhase: String = ""

        let result = runFsck(
            onProgress: { phase, done, total in
                let now = monotonicNanos()
                let phaseChanged = phase != lastPhase
                let intervalElapsed = lastEmitMonotonic == 0
                    || (now &- lastEmitMonotonic) >= minIntervalNs
                guard phaseChanged || intervalElapsed else { return }
                lastEmitMonotonic = now
                lastPhase = phase
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
        deactivateNow()
    }

    /// The body of `deactivate`, which a test can call without an
    /// FSDeactivateOptions.
    func deactivateNow() {
        // Stop the stats heartbeat first so the final tally lands while
        // the AppLog sinks are still alive.
        stats.stop()
        backend.unmount()
        backend.releaseDevice()
    }

    // MARK: - File attributes

    func attributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem
    ) async throws -> FSItem.Attributes {
        guard backend.isMounted, let ntfsItem = item as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }

        // Ghost AppleDouble — return synthetic attrs without hitting bridge.
        if Self.isAppleDouble(path: ntfsItem.path) {
            return Self.ghostAppleDoubleAttributes(
                for: ntfsItem.path,
                parentRecordNumber: ntfsItem.parentRecordNumber)
        }

        guard let attr = backend.stat(ntfsItem.volumePath) else {
            throw backend.lastError()
        }

        return Self.attributes(from: attr,
                               parentRecordNumber: ntfsItem.parentRecordNumber)
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem
    ) async throws -> FSItem.Attributes {
        guard backend.isMounted, let ntfsItem = item as? NTFSItem else {
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
            return Self.ghostAppleDoubleAttributes(
                for: ntfsItem.path,
                parentRecordNumber: ntfsItem.parentRecordNumber)
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
            guard let current = backend.stat(ntfsItem.volumePath) else {
                throw backend.lastError()
            }
            if newSize > current.size {
                // Grow not supported by fs_ntfs_truncate_h yet.
                throw fs_errorForPOSIXError(ENOTSUP)
            }
            if backend.truncate(ntfsItem.volumePath, to: newSize) < 0 {
                throw backend.lastError()
            }
            consumed.insert(.size)
        }

        // Times: convert UNIX timespecs to NTFS FILETIME (100ns ticks
        // since 1601-01-01 UTC). Nil for any time we aren't touching.
        var times = NTFSFileTimes()
        if newAttributes.isValid(.addedTime) {
            times.creation = Self.filetimeFromTimespec(newAttributes.addedTime)
        }
        if newAttributes.isValid(.modifyTime) {
            times.modification = Self.filetimeFromTimespec(newAttributes.modifyTime)
        }
        if newAttributes.isValid(.changeTime) {
            times.change = Self.filetimeFromTimespec(newAttributes.changeTime)
        }
        if newAttributes.isValid(.accessTime) {
            times.access = Self.filetimeFromTimespec(newAttributes.accessTime)
        }

        if times != NTFSFileTimes() {
            if backend.setTimes(ntfsItem.volumePath, times) != 0 { throw backend.lastError() }
            if times.creation != nil { consumed.insert(.addedTime) }
            if times.modification != nil { consumed.insert(.modifyTime) }
            if times.change != nil { consumed.insert(.changeTime) }
            if times.access != nil { consumed.insert(.accessTime) }
        }

        newAttributes.consumedAttributes = consumed

        // Re-stat to return the post-mutation attributes.
        guard let attr = backend.stat(ntfsItem.volumePath) else {
            throw backend.lastError()
        }
        return Self.attributes(from: attr,
                               parentRecordNumber: ntfsItem.parentRecordNumber)
    }

    // MARK: - Lookup

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> (FSItem, FSFileName) {
        guard backend.isMounted, let dirItem = directory as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }

        // By the name's bytes: `name.string` is nil for a name that is not
        // UTF-8. NTFS cannot hold one, so it is refused as EILSEQ rather
        // than EINVAL, and without reaching the driver (diskjockey#219).
        let childPath: VolumePath
        do {
            childPath = try dirItem.volumePath.child(name, for: Self.pathEncoding)
        } catch let error as POSIXError {
            throw fs_errorForPOSIXError(error.code.rawValue)
        }

        // The driver's reason, not a blanket ENOENT: ENOENT tells FSKit
        // the name does not exist, which is not what an I/O error means.
        // A missing name is ENOENT from the driver itself.
        guard let attr = backend.stat(childPath) else {
            throw backend.lastError()
        }

        let foundItem = item(forRecordNumber: attr.recordNumber,
                             path: childPath.description,
                             parentRecordNumber: dirItem.fileRecordNumber)
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
        guard backend.isMounted, let dirItem = directory as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }
        let end = try entries(of: dirItem, after: cookie.rawValue,
                              withAttributes: attributes != nil) { $0.pack(into: packer) }
        return FSDirectoryVerifier(rawValue: end)
    }

    /// The body of `enumerateDirectory`, with the packer as a closure so
    /// a test can stand in for it (FSKit's packer cannot be constructed).
    /// Answers the cookie after the last entry packed.
    func entries(
        of dirItem: NTFSItem,
        after startCookie: UInt64,
        withAttributes: Bool,
        pack: (PackableDirectoryEntry) -> Bool
    ) throws -> UInt64 {
        var entryCookie: UInt64 = 1

        let walk = backend.walkDirectory(dirItem.volumePath) { entry in
            if entryCookie <= startCookie {
                entryCookie += 1
                return true
            }
            // The driver synthesises "." and ".." at the head of every
            // listing. FSVolume.h: "Don't pack "." and ".." if
            // `attributes` isn't nil." They keep their cookies, so a
            // listing resumes at the same place either way.
            if withAttributes, entry.name == Self.dot || entry.name == Self.dotDot {
                entryCookie += 1
                return true
            }

            // The bytes, never a repaired String (diskjockey#219). The
            // driver converts NTFS's UTF-16 names to UTF-8, so a name that
            // does not decode is a driver fault: it is listed as it came,
            // and not stat'ed through a path the driver would refuse.
            let childPath = try? dirItem.volumePath.child(entry.name, for: Self.pathEncoding)

            var itemAttrs: FSItem.Attributes? = nil
            if withAttributes {
                // Always populate FSKit's full standard attribute set —
                // see `attributes(from:parentRecordNumber:)` for the
                // contract. An incomplete mask (missing flags /
                // parentID / birthTime) makes the connector reject
                // the reply, which surfaces to userspace as "file
                // vanished."
                if let childPath, let attr = backend.stat(childPath) {
                    itemAttrs = Self.attributes(
                        from: attr,
                        parentRecordNumber: dirItem.fileRecordNumber)
                }
            }

            let packed = pack(PackableDirectoryEntry(
                name: DirentName.fileName(entry.name),
                itemType: Self.fsItemType(from: entry.fileType),
                itemID: FSItem.Identifier(rawValue: entry.recordNumber)!,
                nextCookie: FSDirectoryCookie(rawValue: entryCookie),
                attributes: itemAttrs))
            if !packed { return false }
            entryCookie += 1
            return true
        }

        switch walk {
        case .finished:
            return entryCookie
        case .openFailed:
            throw backend.lastError()
        case .failedPartway:
            // A name whose length the dirent's own array cannot hold.
            throw fs_errorForPOSIXError(EIO)
        }
    }

    // MARK: - Reclaim

    func reclaimItem(_ item: FSItem) async throws {
        if let ntfsItem = item as? NTFSItem {
            items.remove(id: ntfsItem.fileRecordNumber)
        }
    }

    // MARK: - Symlink

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        guard backend.isMounted, let ntfsItem = item as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }

        // Success is the target's length, not zero (see SymlinkTarget).
        // Handed to FSKit as the bytes the driver wrote (diskjockey#219).
        let target = try SymlinkTarget.readBytes(
            lastErrno: { backend.lastErrno() },
            error: { fs_errorForPOSIXError($0) }
        ) { buf, size in
            backend.readlink(ntfsItem.volumePath, buf, size)
        }
        return FSFileName(data: Data(target))
    }

    // MARK: - Mutating ops

    func createItem(
        named name: FSFileName, type: FSItem.ItemType,
        inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest
    ) async throws -> (FSItem, FSFileName) {
        guard backend.isMounted, let dirItem = directory as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }
        guard let nameStr = name.string else {
            throw fs_errorForPOSIXError(EINVAL)
        }
        let childPath = Self.joinPath(dirItem.path, nameStr)

        // AppleDouble (`._foo`) — silently swallow create. Returns a
        // ghost FSItem whose subsequent write/read/attr/remove ops are
        // handled inline below. We never touch the underlying NTFS
        // filesystem for these names — they only carry HFS-specific
        // resource-fork / FinderInfo metadata that's irrelevant on
        // NTFS volumes that round-trip back to Linux/Windows.
        if Self.isAppleDouble(name: nameStr) {
            log.info("createItem: silently swallowing AppleDouble \(childPath)", scope: AppLogScope.enumerate)
            let ghost = item(forRecordNumber: Self.appleDoubleGhostRecord,
                             path: childPath,
                             parentRecordNumber: dirItem.fileRecordNumber)
            attributes.consumedAttributes = [.mode, .uid, .gid, .accessTime, .modifyTime]
            return (ghost, name)
        }

        let mftNum: Int64
        switch type {
        case .file:
            mftNum = backend.createFile(in: dirItem.volumePath, named: nameStr)
        case .directory:
            mftNum = backend.mkdir(in: dirItem.volumePath, named: nameStr)
        case .symlink:
            // TODO: needs fs_ntfs_create_symlink_h — the path-based
            // fs_ntfs_create_symlink can't be used through a callback-
            // mounted handle, so we can't honour symlink creation here.
            throw fs_errorForPOSIXError(ENOTSUP)
        default:
            throw fs_errorForPOSIXError(ENOTSUP)
        }

        if mftNum < 0 {
            throw backend.lastError()
        }

        let newItem = item(forRecordNumber: UInt64(mftNum),
                           path: childPath,
                           parentRecordNumber: dirItem.fileRecordNumber)

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
        guard backend.isMounted, let ntfsItem = item as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }

        // Ghost AppleDouble — never existed on disk, succeed silently.
        if let nameStr = name.string, Self.isAppleDouble(name: nameStr) {
            return
        }

        guard let attr = backend.stat(ntfsItem.volumePath) else {
            throw backend.lastError()
        }

        let rc: Int32
        switch attr.fileType {
        case .directory, .junction:
            rc = backend.rmdir(ntfsItem.volumePath)
        case .file, .symlink:
            rc = backend.unlink(ntfsItem.volumePath)
        case .unknown:
            throw fs_errorForPOSIXError(ENOTSUP)
        }

        if rc != 0 {
            throw backend.lastError()
        }
    }

    func renameItem(
        _ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
        to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?
    ) async throws -> FSFileName {
        guard backend.isMounted,
              let srcDir = sourceDirectory as? NTFSItem,
              let dstDir = destinationDirectory as? NTFSItem,
              let ntfsItem = item as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }
        guard let dstNameStr = destinationName.string else {
            throw fs_errorForPOSIXError(EINVAL)
        }

        // TODO: cross-directory rename needs follow-up Rust support —
        // fs_ntfs_rename2_h takes a NEW BASENAME only.
        if srcDir !== dstDir && srcDir.path != dstDir.path {
            throw fs_errorForPOSIXError(ENOTSUP)
        }

        // The backend renames with FS_NTFS_RENAME_REPLACE, which atomically
        // replaces an existing destination (POSIX rename(2) semantics),
        // enforced inside the crate: file→file frees the old record +
        // clusters, empty-dir → empty-dir overwrites, and crossing the
        // file/directory boundary or a non-empty dir target fails with
        // EISDIR / ENOTDIR / ENOTEMPTY. We no longer remove the destination
        // ourselves — that was non-atomic and lost the original if the
        // rename then failed — and we can't rely on `overItem` being
        // populated: FSKit only passes it when the kernel had already
        // resolved the destination, so a rename-over (e.g. `sed -i`) would
        // otherwise slip through with a nil overItem.
        if backend.rename(ntfsItem.volumePath, toBasename: dstNameStr) != 0 {
            throw backend.lastError()
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
            let n = try buffer.withUnsafeMutableBytes { rawBuf in
                try readBytes(from: item, at: offset,
                              into: UnsafeMutableRawBufferPointer(rebasing: rawBuf.prefix(length)))
            }
            stats.recordRead(bytes: n, latencyNs: monotonicNanos() &- t0, error: false)
            return n
        } catch {
            stats.recordRead(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
            throw error
        }
    }

    /// The body of `read`, over a plain buffer so a test can supply one
    /// (FSKit's FSMutableFileDataBuffer cannot be constructed).
    func readBytes(
        from item: FSItem, at offset: off_t,
        into buffer: UnsafeMutableRawBufferPointer
    ) throws -> Int {
        guard backend.isMounted, let ntfsItem = item as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }

        // Ghost AppleDouble — files are always empty, return 0 (EOF).
        if Self.isAppleDouble(path: ntfsItem.path) {
            return 0
        }

        let bytesRead = backend.read(ntfsItem.volumePath, at: UInt64(offset), into: buffer)
        // Negative is a failure. It was clamped to zero once, and zero
        // bytes is how FSKit learns it has reached the end of the file,
        // so a read error became a silently short copy.
        guard bytesRead >= 0 else { throw backend.lastError() }
        return Int(bytesRead)
    }

    func write(
        contents data: Data, to item: FSItem, at offset: off_t
    ) async throws -> Int {
        let t0 = monotonicNanos()
        do {
            let n = try writeBytes(contents: data, to: item, at: offset)
            stats.recordWrite(bytes: n, latencyNs: monotonicNanos() &- t0, error: false)
            return n
        } catch {
            stats.recordWrite(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
            throw error
        }
    }

    /// The body of `write`.
    func writeBytes(
        contents data: Data, to item: FSItem, at offset: off_t
    ) throws -> Int {
        guard backend.isMounted, let ntfsItem = item as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
        }

        // Ghost AppleDouble — accept the bytes, write nowhere.
        if Self.isAppleDouble(path: ntfsItem.path) { return data.count }

        // POSIX write(2): zero bytes "shall return zero and have no other
        // results". The whole-file rewrite below is sized to
        // max(size, offset + count), so an empty write past the end grew
        // the file with zeros.
        if data.isEmpty { return 0 }

        // IMPORTANT: fs_ntfs_write_file_contents_h replaces the WHOLE
        // file. To emulate offset/partial writes we read-modify-write —
        // stat the current size, build a buffer of
        // max(currentSize, offset + data.count), splice the new bytes
        // in at `offset`, then call write_file_contents with the merged
        // buffer. This is O(filesize) per write — slow but correct.
        // TODO: replace with streaming write API when fs_ntfs exposes it.

        guard let attr = backend.stat(ntfsItem.volumePath) else {
            throw backend.lastError()
        }

        let writeOffset = UInt64(offset)
        let writeLen = UInt64(data.count)

        // Fast path: writing from offset 0 fully replaces or extends the
        // file — skip the read-modify-write step.
        if writeOffset == 0 && writeLen >= attr.size {
            return try writeFastPath(path: ntfsItem.volumePath, data: data)
        }
        return try writeSlowPath(path: ntfsItem.volumePath, data: data,
                                 currentSize: attr.size, at: writeOffset)
    }

    private func writeFastPath(path: VolumePath, data: Data) throws -> Int {
        let written = data.withUnsafeBytes { backend.writeContents(path, $0) }
        if written < 0 { throw backend.lastError() }
        return data.count
    }

    private func writeSlowPath(
        path: VolumePath, data: Data,
        currentSize: UInt64, at writeOffset: UInt64
    ) throws -> Int {
        let mergedSize = max(currentSize, writeOffset + UInt64(data.count))
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: Int(mergedSize), alignment: 8)
        defer { buf.deallocate() }
        buf.initializeMemory(as: UInt8.self, repeating: 0)

        if currentSize > 0 {
            let read = backend.read(path, at: 0,
                                    into: UnsafeMutableRawBufferPointer(rebasing: buf.prefix(Int(currentSize))))
            if read < 0 || UInt64(read) < currentSize { throw backend.lastError() }
        }

        data.withUnsafeBytes { rawBuf in
            if let base = rawBuf.baseAddress, !rawBuf.isEmpty {
                memcpy(buf.baseAddress!.advanced(by: Int(writeOffset)), base, data.count)
            }
        }

        let written = backend.writeContents(path, UnsafeRawBufferPointer(buf))
        if written < 0 { throw backend.lastError() }
        return data.count
    }

    // MARK: - PathConfOperations

    var maximumLinkCount: Int { 1024 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }

    // MARK: - Helpers

    static func fsItemType(from type: NTFSFileType) -> FSItem.ItemType {
        switch type {
        case .file:      return .file
        case .directory: return .directory
        case .symlink:   return .symlink
        default:         return .file
        }
    }

    static let dot: [UInt8] = [UInt8(ascii: ".")]
    static let dotDot: [UInt8] = [UInt8(ascii: "."), UInt8(ascii: ".")]

    /// Join a parent directory path to a child name, taking care to avoid
    /// the double-slash "//foo" trap when the parent is the root.
    static func joinPath(_ parent: String, _ child: String) -> String {
        return parent == "/" ? "/\(child)" : "\(parent)/\(child)"
    }

    /// Build an `FSItem.Attributes` snapshot from the driver's stat.
    ///
    /// Populates **every bit in FSKit's standard attribute set** —
    /// `type, mode, linkCount, flags, size, allocSize, fileID,
    /// parentID, accessTime, modifyTime, changeTime, birthTime`.
    /// Missing any of these makes
    /// `FSVolumeConnector.getStandardItemAttributesForItem` reject the
    /// reply with errno 2 (ENOENT), which surfaces to userspace as
    /// "file vanished after save". See
    /// `DiskJockeyEXT4CoreTests/EXT4VolumeAttributesTests.swift` for the
    /// FSKit bit layout — same contract here.
    ///
    /// `parentRecordNumber` is `nil` only for the root directory — its
    /// parent is the FSKit-defined `FSItemIDParentOfRoot` (1).
    static func attributes(from attr: NTFSFileAttributes,
                           parentRecordNumber: UInt64?) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.type = fsItemType(from: attr.fileType)
        attrs.mode = UInt32(attr.mode)
        attrs.uid = 0
        attrs.gid = 0
        // Map NTFS hidden/system bits → UF_HIDDEN so Finder doesn't display
        // $MFT, $AttrDef, $Bitmap etc. at the root of every volume.
        let isHidden = (attr.fileAttributes & (Self.ntfsAttrHidden | Self.ntfsAttrSystem)) != 0
        attrs.flags = isHidden ? Self.bsdFlagHidden : 0
        attrs.size = attr.size
        attrs.linkCount = UInt32(attr.linkCount)
        attrs.allocSize = attr.size
        attrs.accessTime = timespec(tv_sec: Int(attr.accessTime.sec), tv_nsec: Int(attr.accessTime.nsec))
        attrs.modifyTime = timespec(tv_sec: Int(attr.modifyTime.sec), tv_nsec: Int(attr.modifyTime.nsec))
        attrs.changeTime = timespec(tv_sec: Int(attr.changeTime.sec), tv_nsec: Int(attr.changeTime.nsec))
        // NTFS stores StandardInformation::CreationTime as the birth
        // time. The previous code routed it into addedTime (an
        // HFS+/APFS concept), which left FSKit's required birthTime
        // bit unset.
        attrs.birthTime = timespec(tv_sec: Int(attr.creationTime.sec), tv_nsec: Int(attr.creationTime.nsec))
        if let id = FSItem.Identifier(rawValue: attr.recordNumber) {
            attrs.fileID = id
        }
        let parentRaw = parentRecordNumber ?? 1
        if let parentID = FSItem.Identifier(rawValue: parentRaw) {
            attrs.parentID = parentID
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
