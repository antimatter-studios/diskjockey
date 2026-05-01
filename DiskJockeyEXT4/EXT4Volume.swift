/*
 * EXT4Volume.swift — FSKit volume backed by a FileSystemBackend.
 *
 * All file operations are dispatched through the backend protocol,
 * making this volume implementation reusable across different data
 * sources (local ext4, remote Dropbox, S3, etc.).
 *
 * Uses async/await FSKit API (macOS 15.6+) to avoid deadlocking
 * FSKit's internal queues when doing synchronous C bridge I/O.
 *
 * MIT License — see LICENSE
 */

import FSKit
import Foundation
import os

/// Represents a mounted volume backed by any FileSystemBackend.
final class EXT4Volume: FSVolume,
                        FSVolume.Operations,
                        FSVolume.PathConfOperations,
                        FSVolume.ReadWriteOperations {

    /// The pluggable backend providing filesystem data
    let backend: FileSystemBackend

    /// Retains the BlockDeviceContext so it lives as long as the volume
    private var blockDeviceContext: UnsafeMutableRawPointer?

    /// True when `loadResource` mounted in RW-with-deferred-replay mode
    /// (i.e. used `fs_ext4_mount_rw_with_callbacks_lazy`). When set, the
    /// first `activate(options:)` call must invoke
    /// `backend.replayJournalIfDirty()` to complete the mount. Workaround
    /// for a macOS FSKit limitation where the kernel write FD only
    /// becomes truly writable AFTER loadResource returns, so doing
    /// journal replay during loadResource fails with EIO mid-mount.
    private let requiresJournalReplay: Bool

    /// Per-mount I/O counter aggregator. Owns the 1 Hz `io.stats`
    /// emitter that the host app's AttachedDisksModel ingests. Started
    /// in `EXT4FileSystem.loadResource`, stopped in `deactivate`.
    private let stats: IOStatsCollector

    /// Track items by file ID for reclamation. Guarded by `itemsLock` — an
    /// `OSAllocatedUnfairLock` is used (rather than `NSLock`) so the class
    /// is Sendable-safe under Swift 6 strict concurrency; holding an unfair
    /// lock across an `await` is a compile-time error, which matches the
    /// invariant we already rely on here.
    private let itemsLock = OSAllocatedUnfairLock<[UInt64: EXT4Item]>(initialState: [:])

    /// Shared App Group store. Used to read live toggles (e.g. verbose
    /// enumerate logging) the host app writes via `@AppStorage`. Reads
    /// are lock-free per-thread; CFPreferences caches.
    private static let appGroupDefaults = UserDefaults(
        suiteName: "group.com.antimatterstudios.diskjockey")

    private static var isVerboseEnumerateLogEnabled: Bool {
        appGroupDefaults?.bool(forKey: "verboseEnumerateLog") ?? false
    }

    /// Sentinel inode used for ghost AppleDouble (`._*`) items we silently
    /// swallow. Picked at the top of the 32-bit space, well outside any
    /// inode the ext4 driver would ever assign to a real file.
    private static let appleDoubleGhostInode: UInt32 = 0xFFFF_FFFE

    /// Returns true if the basename starts with `._` — macOS Finder /
    /// Desktop Services AppleDouble metadata. We silently swallow
    /// creates and subsequent ops on these files: accept the operation
    /// (apps don't error) but never persist the bytes to disk.
    /// Justification: AppleDouble files only carry HFS-specific
    /// resource-fork / FinderInfo metadata that's irrelevant on
    /// ext4 volumes that round-trip back to Linux/Windows.
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
        attrs.fileID = FSItem.Identifier(rawValue: UInt64(appleDoubleGhostInode))!
        return attrs
    }

    init(volumeID: FSVolume.Identifier,
         volumeName: FSFileName,
         backend: FileSystemBackend,
         blockDeviceContext: UnsafeMutableRawPointer? = nil,
         requiresJournalReplay: Bool,
         stats: IOStatsCollector) {
        self.backend = backend
        self.blockDeviceContext = blockDeviceContext
        self.requiresJournalReplay = requiresJournalReplay
        self.stats = stats
        super.init(volumeID: volumeID, volumeName: volumeName)
    }

    // MARK: - Item management

    private func item(forID fileID: UInt64, path: String) -> EXT4Item {
        itemsLock.withLock { items in
            if let existing = items[fileID] {
                return existing
            }
            let newItem = EXT4Item(inode: UInt32(fileID), path: path)
            items[fileID] = newItem
            return newItem
        }
    }

    // MARK: - Volume capabilities

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsPersistentObjectIDs = true
        caps.supportsSymbolicLinks = true
        caps.supportsHardLinks = true
        // ext4 has a JBD2 journal; the driver replays it on mount.
        caps.supportsJournal = true
        caps.supportsActiveJournal = true
        // ext4 supports sparse files and large (>4 GB) files.
        caps.supportsSparseFiles = true
        caps.supports2TBFiles = true
        // ext4 inode #s are 32-bit; 64-bit object IDs are not used.
        caps.supports64BitObjectIDs = false
        // ext4 is case-sensitive.
        caps.caseFormat = .sensitive
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        let info = backend.volumeInfo()
        let stats = FSStatFSResult(fileSystemTypeName: "ext4")

        stats.blockSize = Int(info.blockSize)
        stats.ioSize = Int(info.blockSize)
        stats.totalBlocks = info.totalBlocks
        stats.availableBlocks = 0
        stats.freeBlocks = info.freeBlocks
        stats.totalFiles = UInt64(info.totalInodes)
        stats.freeFiles = UInt64(info.freeInodes)

        return stats
    }

    // MARK: - Mount/unmount (async)

    func mount(options: FSTaskOptions) async throws {
        log.info("volume: mount", scope: AppLogScope.lifecycle)
    }

    func unmount() async {
        log.info("volume: unmount", scope: AppLogScope.lifecycle)
        backend.shutdown()
    }

    // MARK: - Activate/Deactivate (async)

    func activate(options: FSTaskOptions) async throws -> FSItem {
        log.info("volume: activate", scope: AppLogScope.lifecycle)
        if requiresJournalReplay {
            log.info("volume: invoking deferred journal replay via backend", scope: AppLogScope.lifecycle)
            if !backend.replayJournalIfDirty() {
                // Replay failed. Don't fail the whole mount — the volume is
                // still usable read-only. Surface as an event the host app
                // can show. Future writes will likely fail until the user
                // remediates externally.
                log.error("volume: deferred journal replay FAILED — volume continues but writes may not be safe", scope: AppLogScope.lifecycle)
            } else {
                log.info("volume: journal replay completed (or volume was clean)", scope: AppLogScope.lifecycle)
            }
        }
        return item(forID: 2, path: "/")
    }

    func deactivate(options: FSDeactivateOptions) async throws {
        log.info("volume: deactivate", scope: AppLogScope.lifecycle)
        // Stop the stats heartbeat first so the final tally is flushed
        // while the AppLog sinks are still alive.
        stats.stop()
        backend.shutdown()
        if let ctx = blockDeviceContext {
            Unmanaged<BlockDeviceContext>.fromOpaque(ctx).release()
            blockDeviceContext = nil
        }
    }

    // MARK: - File attributes (async)

    func attributes(_ desiredAttributes: FSItem.GetAttributesRequest,
                    of item: FSItem) async throws -> FSItem.Attributes {
        guard let ext4Item = item as? EXT4Item else {
            throw POSIXError(.EBADF)
        }

        // Ghost AppleDouble — return synthetic attrs without hitting backend.
        if Self.isAppleDouble(path: ext4Item.path) {
            return Self.ghostAppleDoubleAttributes(for: ext4Item.path)
        }

        guard let attr = backend.stat(path: ext4Item.path) else {
            throw POSIXError(.ENOENT)
        }

        let attrs = FSItem.Attributes()
        attrs.type = Self.fsItemType(from: attr.fileType)
        attrs.mode = UInt32(attr.mode & 0o7777)
        attrs.uid = uid_t(attr.uid)
        attrs.gid = gid_t(attr.gid)
        attrs.size = attr.size
        attrs.linkCount = UInt32(attr.linkCount)
        attrs.allocSize = attr.size

        attrs.accessTime = timespec(tv_sec: Int(attr.atime), tv_nsec: 0)
        attrs.modifyTime = timespec(tv_sec: Int(attr.mtime), tv_nsec: 0)
        attrs.changeTime = timespec(tv_sec: Int(attr.ctime), tv_nsec: 0)

        if attr.crtime > 0 {
            attrs.addedTime = timespec(tv_sec: Int(attr.crtime), tv_nsec: 0)
        }

        attrs.fileID = FSItem.Identifier(rawValue: attr.fileID)!
        return attrs
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest,
                       on item: FSItem) async throws -> FSItem.Attributes {
        guard let ext4Item = item as? EXT4Item else {
            throw POSIXError(.EBADF)
        }

        // Ghost AppleDouble — pretend every attribute was applied,
        // return synthetic state. Nothing hits the backend.
        if Self.isAppleDouble(path: ext4Item.path) {
            newAttributes.consumedAttributes = [.mode, .uid, .gid, .accessTime, .modifyTime, .size]
            return Self.ghostAppleDoubleAttributes(for: ext4Item.path)
        }

        // Track which attributes we successfully consumed so the kernel
        // knows what to mark as applied (and what to retry / drop).
        var consumed: FSItem.Attribute = []

        if newAttributes.isValid(.mode) {
            let mode = UInt16(newAttributes.mode & 0o7777)
            guard backend.chmod(path: ext4Item.path, mode: mode) else {
                throw Self.posixError(from: backend)
            }
            consumed.insert(.mode)
        }

        if newAttributes.isValid(.uid) || newAttributes.isValid(.gid) {
            let uid: UInt32? = newAttributes.isValid(.uid) ? UInt32(newAttributes.uid) : nil
            let gid: UInt32? = newAttributes.isValid(.gid) ? UInt32(newAttributes.gid) : nil
            guard backend.chown(path: ext4Item.path, uid: uid, gid: gid) else {
                throw Self.posixError(from: backend)
            }
            if uid != nil { consumed.insert(.uid) }
            if gid != nil { consumed.insert(.gid) }
        }

        if newAttributes.isValid(.size) {
            guard backend.truncate(path: ext4Item.path, size: newAttributes.size) else {
                throw Self.posixError(from: backend)
            }
            consumed.insert(.size)
        }

        if newAttributes.isValid(.accessTime) || newAttributes.isValid(.modifyTime) {
            let atime: timespec? = newAttributes.isValid(.accessTime) ? newAttributes.accessTime : nil
            let mtime: timespec? = newAttributes.isValid(.modifyTime) ? newAttributes.modifyTime : nil
            guard backend.utimens(path: ext4Item.path, atime: atime, mtime: mtime) else {
                throw Self.posixError(from: backend)
            }
            if atime != nil { consumed.insert(.accessTime) }
            if mtime != nil { consumed.insert(.modifyTime) }
        }

        newAttributes.consumedAttributes = consumed

        // Re-stat to return the canonical post-modification attributes.
        guard let attr = backend.stat(path: ext4Item.path) else {
            throw POSIXError(.ENOENT)
        }
        return Self.attributes(from: attr)
    }

    // MARK: - Lookup (async)

    func lookupItem(named name: FSFileName,
                    inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        guard let dirItem = directory as? EXT4Item else {
            throw POSIXError(.EBADF)
        }

        guard let nameStr = name.string else {
            throw POSIXError(.EINVAL)
        }

        let childPath = dirItem.path == "/" ? "/\(nameStr)" : "\(dirItem.path)/\(nameStr)"

        guard let attr = backend.stat(path: childPath) else {
            throw POSIXError(.ENOENT)
        }

        return (item(forID: attr.fileID, path: childPath), name)
    }

    // MARK: - Directory enumeration (async)

    func enumerateDirectory(_ directory: FSItem,
                            startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier {
        guard let dirItem = directory as? EXT4Item else {
            throw POSIXError(.EBADF)
        }
        let verbose = Self.isVerboseEnumerateLogEnabled
        if verbose {
            log.info("enumerateDirectory path=\(dirItem.path) cookie=\(cookie.rawValue) attrsReq=\(attributes != nil)", scope: AppLogScope.enumerate)
        }

        guard let entries = backend.readDirectory(path: dirItem.path) else {
            throw POSIXError(.EIO)
        }

        // Per-entry logging is debug-grade and floods the log when
        // Spotlight enumerates a tree, so it sits behind the App Group
        // toggle `verboseEnumerateLog`. Off by default; flip it on
        // from the disk detail pane when investigating something.
        // When on, we log the FULL path of each child so the structure
        // of the tree being walked is visible in the log.
        if verbose {
            for (i, e) in entries.enumerated() {
                let childPath = Self.joinPath(dirItem.path, e.name)
                log.info("  entry[\(i)] path=\(childPath) fileID=\(e.fileID) fileType=\(String(describing: e.fileType))", scope: AppLogScope.enumerate)
            }
        }

        let startCookie = cookie.rawValue
        var packedCount = 0
        var stopped = false

        for (index, entry) in entries.enumerated() {
            let entryCookie = UInt64(index + 1)

            if entryCookie <= startCookie { continue }

            // Skip "." and ".." — FSKit populates these itself.
            if entry.name == "." || entry.name == ".." { continue }

            let fsName = FSFileName(string: entry.name)
            let itemType = Self.fsItemType(from: entry.fileType)

            var itemAttrs: FSItem.Attributes? = nil
            if attributes != nil {
                // Always populate at least minimal attributes when requested.
                // FSKit errors out if attributes were requested but nil.
                let attrs = FSItem.Attributes()
                attrs.type = itemType
                attrs.fileID = FSItem.Identifier(rawValue: entry.fileID) ?? FSItem.Identifier(rawValue: 1)!
                attrs.linkCount = 1
                attrs.mode = itemType == .directory ? 0o755 : 0o644

                // Upgrade with richer info from stat when available.
                let childPath = dirItem.path == "/" ? "/\(entry.name)" : "\(dirItem.path)/\(entry.name)"
                if let stat = backend.stat(path: childPath) {
                    attrs.mode = UInt32(stat.mode & 0o7777)
                    attrs.uid = uid_t(stat.uid)
                    attrs.gid = gid_t(stat.gid)
                    attrs.size = stat.size
                    attrs.linkCount = UInt32(stat.linkCount)
                }
                itemAttrs = attrs
            }

            let packed = packer.packEntry(
                name: fsName,
                itemType: itemType,
                itemID: FSItem.Identifier(rawValue: entry.fileID) ?? FSItem.Identifier(rawValue: 1)!,
                nextCookie: FSDirectoryCookie(rawValue: entryCookie),
                attributes: itemAttrs
            )

            if packed { packedCount += 1 } else { stopped = true; break }
        }

        if verbose {
            log.info("enumerateDirectory done: packed=\(packedCount) total=\(entries.count) stopped=\(stopped)", scope: AppLogScope.enumerate)
        }
        return FSDirectoryVerifier(rawValue: UInt64(entries.count + 1))
    }

    // MARK: - Reclaim (async)

    func reclaimItem(_ item: FSItem) async throws {
        if let ext4Item = item as? EXT4Item {
            let key = UInt64(ext4Item.inode)
            itemsLock.withLock { items in
                items.removeValue(forKey: key)
            }
        }
    }

    // MARK: - File read/write (async)

    func write(contents data: Data, to item: FSItem, at offset: off_t) async throws -> Int {
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

    private func writeImpl(contents data: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        guard let ext4Item = item as? EXT4Item else {
            throw POSIXError(.EBADF)
        }

        // Ghost AppleDouble — accept the bytes, write nowhere.
        if Self.isAppleDouble(path: ext4Item.path) {
            return data.count
        }

        // IMPORTANT: `fs_ext4_write_file` replaces the WHOLE file. To
        // emulate partial / offset writes we read-modify-write: stat the
        // current size, build a buffer of `max(currentSize, offset+len)`,
        // splice the new bytes in at `offset`, then call writeFile with
        // the merged buffer. This is O(filesize) per write and slow on
        // large files.
        //
        // The Rust crate's TODO list says "appends / partial writes are
        // follow-up work" — once it exposes a streaming write, this
        // method should call straight through without round-tripping
        // existing contents.

        guard let attr = backend.stat(path: ext4Item.path) else {
            throw POSIXError(.ENOENT)
        }

        let currentSize = attr.size
        let writeOffset = UInt64(offset)
        let writeLen = UInt64(data.count)
        let newEnd = writeOffset + writeLen

        // Fast path: rewriting from offset 0 fully replaces or extends the
        // file. Skip the read-modify-write step entirely.
        if writeOffset == 0 && writeLen >= currentSize {
            let written: Int64 = data.withUnsafeBytes { rawBuf -> Int64 in
                guard let base = rawBuf.baseAddress else { return -1 }
                return backend.writeFile(path: ext4Item.path, data: base, length: writeLen)
            }
            if written < 0 { throw Self.posixError(from: backend) }
            return Int(writeLen)
        }

        // Slow path: read-modify-write.
        let mergedSize = max(currentSize, newEnd)
        let bufferSize = Int(mergedSize)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buf.deallocate() }
        memset(buf, 0, bufferSize)

        if currentSize > 0 {
            let read = backend.readFile(path: ext4Item.path,
                                         offset: 0,
                                         length: currentSize,
                                         buffer: buf)
            if read < 0 || UInt64(read) < currentSize {
                throw Self.posixError(from: backend)
            }
        }

        data.withUnsafeBytes { rawBuf in
            if let base = rawBuf.baseAddress, !rawBuf.isEmpty {
                memcpy(buf.advanced(by: Int(writeOffset)), base, data.count)
            }
        }

        let written = backend.writeFile(path: ext4Item.path, data: buf, length: mergedSize)
        if written < 0 { throw Self.posixError(from: backend) }
        return data.count
    }

    func read(from item: FSItem, at offset: off_t, length: Int,
              into buffer: FSMutableFileDataBuffer) async throws -> Int {
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

    private func readImpl(from item: FSItem, at offset: off_t, length: Int,
                          into buffer: FSMutableFileDataBuffer) async throws -> Int {
        guard let ext4Item = item as? EXT4Item else {
            throw POSIXError(.EBADF)
        }

        // Ghost AppleDouble — files are always empty, return 0 (EOF).
        if Self.isAppleDouble(path: ext4Item.path) {
            return 0
        }

        // Use the backend's read callback into the FSKit buffer's raw pointer.
        let capacity = buffer.length
        let readLen = min(length, capacity)

        let bytesRead: Int64 = buffer.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return -1 }
            return backend.readFile(path: ext4Item.path,
                                    offset: UInt64(offset),
                                    length: UInt64(readLen),
                                    buffer: base)
        }

        if bytesRead < 0 {
            log.error("read(from: \(ext4Item.path)): backend returned \(bytesRead)", scope: AppLogScope.io)
            throw POSIXError(.EIO)
        }
        return Int(bytesRead)
    }

    // MARK: - Symlink (async)

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        guard let ext4Item = item as? EXT4Item else {
            throw POSIXError(.EBADF)
        }

        guard let target = backend.readSymlink(path: ext4Item.path) else {
            throw POSIXError(.EIO)
        }

        return FSFileName(string: target)
    }

    // MARK: - Mutating ops (async)

    func createItem(named name: FSFileName, type: FSItem.ItemType,
                    inDirectory directory: FSItem,
                    attributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        guard let dirItem = directory as? EXT4Item else {
            throw POSIXError(.EBADF)
        }
        guard let nameStr = name.string else {
            throw POSIXError(.EINVAL)
        }
        let childPath = Self.joinPath(dirItem.path, nameStr)

        // AppleDouble (`._foo`) — silently swallow create. Returns a
        // ghost FSItem whose subsequent write/read/attr/remove ops are
        // handled inline below. We never touch the underlying ext4
        // filesystem for these names.
        if Self.isAppleDouble(name: nameStr) {
            log.info("createItem: silently swallowing AppleDouble \(childPath)", scope: AppLogScope.enumerate)
            let ghost = item(forID: UInt64(Self.appleDoubleGhostInode), path: childPath)
            attributes.consumedAttributes = [.mode, .uid, .gid, .accessTime, .modifyTime]
            return (ghost, name)
        }

        // Default mode: 0o644 for files, 0o755 for directories.
        let defaultMode: UInt16 = (type == .directory) ? 0o755 : 0o644
        let modeBits: UInt16 = attributes.isValid(.mode)
            ? UInt16(attributes.mode & 0o7777)
            : defaultMode

        switch type {
        case .file:
            guard backend.createFile(path: childPath, mode: modeBits) else {
                throw Self.posixError(from: backend)
            }
        case .directory:
            guard backend.mkdir(path: childPath, mode: modeBits) else {
                throw Self.posixError(from: backend)
            }
        case .symlink:
            // Symlinks have a dedicated entry point on this protocol; if
            // FSKit ever routes one through createItem we want a clear
            // diagnostic rather than a silent EROFS.
            throw POSIXError(.EINVAL)
        default:
            // Block / char devices, fifos, sockets — fs_ext4 does not
            // expose mknod, so we cannot honour the request.
            throw POSIXError(.ENOSYS)
        }

        // Apply any other attributes the caller supplied (uid / gid / times).
        // Permissions (mode) were already baked into the create call.
        var consumed: FSItem.Attribute = []
        if attributes.isValid(.mode) { consumed.insert(.mode) }

        if attributes.isValid(.uid) || attributes.isValid(.gid) {
            let uid: UInt32? = attributes.isValid(.uid) ? UInt32(attributes.uid) : nil
            let gid: UInt32? = attributes.isValid(.gid) ? UInt32(attributes.gid) : nil
            if backend.chown(path: childPath, uid: uid, gid: gid) {
                if uid != nil { consumed.insert(.uid) }
                if gid != nil { consumed.insert(.gid) }
            }
        }
        if attributes.isValid(.accessTime) || attributes.isValid(.modifyTime) {
            let atime: timespec? = attributes.isValid(.accessTime) ? attributes.accessTime : nil
            let mtime: timespec? = attributes.isValid(.modifyTime) ? attributes.modifyTime : nil
            if backend.utimens(path: childPath, atime: atime, mtime: mtime) {
                if atime != nil { consumed.insert(.accessTime) }
                if mtime != nil { consumed.insert(.modifyTime) }
            }
        }
        attributes.consumedAttributes = consumed

        guard let attr = backend.stat(path: childPath) else {
            throw POSIXError(.ENOENT)
        }
        return (item(forID: attr.fileID, path: childPath), name)
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                            attributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) {
        guard let dirItem = directory as? EXT4Item else {
            throw POSIXError(.EBADF)
        }
        guard let nameStr = name.string, let target = contents.string else {
            throw POSIXError(.EINVAL)
        }
        let childPath = Self.joinPath(dirItem.path, nameStr)
        guard backend.symlink(target: target, linkpath: childPath) else {
            throw Self.posixError(from: backend)
        }
        guard let attr = backend.stat(path: childPath) else {
            throw POSIXError(.ENOENT)
        }
        return (item(forID: attr.fileID, path: childPath), name)
    }

    func createLink(to item: FSItem, named name: FSFileName,
                    inDirectory directory: FSItem) async throws -> FSFileName {
        guard let dirItem = directory as? EXT4Item,
              let ext4Item = item as? EXT4Item else {
            throw POSIXError(.EBADF)
        }
        guard let nameStr = name.string else {
            throw POSIXError(.EINVAL)
        }
        let dstPath = Self.joinPath(dirItem.path, nameStr)
        guard backend.link(src: ext4Item.path, dst: dstPath) else {
            throw Self.posixError(from: backend)
        }
        return name
    }

    func removeItem(_ item: FSItem, named name: FSFileName,
                    fromDirectory directory: FSItem) async throws {
        guard let dirItem = directory as? EXT4Item else {
            throw POSIXError(.EBADF)
        }
        guard let nameStr = name.string else {
            throw POSIXError(.EINVAL)
        }
        let childPath = Self.joinPath(dirItem.path, nameStr)

        // Ghost AppleDouble — never existed on disk, succeed silently.
        if Self.isAppleDouble(name: nameStr) {
            return
        }

        // Stat to dispatch unlink vs rmdir. If stat fails the item is
        // already gone — surface the underlying errno.
        guard let attr = backend.stat(path: childPath) else {
            throw POSIXError(.ENOENT)
        }
        let ok: Bool
        switch attr.fileType {
        case .directory:
            ok = backend.rmdir(path: childPath)
        default:
            ok = backend.unlink(path: childPath)
        }
        if !ok { throw Self.posixError(from: backend) }
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem,
                    named sourceName: FSFileName, to destinationName: FSFileName,
                    inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?) async throws -> FSFileName {
        guard let srcDir = sourceDirectory as? EXT4Item,
              let dstDir = destinationDirectory as? EXT4Item else {
            throw POSIXError(.EBADF)
        }
        guard let srcNameStr = sourceName.string,
              let dstNameStr = destinationName.string else {
            throw POSIXError(.EINVAL)
        }
        let srcPath = Self.joinPath(srcDir.path, srcNameStr)
        let dstPath = Self.joinPath(dstDir.path, dstNameStr)

        // The fs_ext4 rename does not allow renaming onto an existing
        // entry, so when `overItem` is non-nil we have to remove the
        // destination first. POSIX semantics require that an existing
        // directory target be empty; we honour that by routing through
        // rmdir / unlink based on the destination's actual type, not the
        // source's.
        if overItem != nil {
            if let dstAttr = backend.stat(path: dstPath) {
                let removed: Bool
                switch dstAttr.fileType {
                case .directory:
                    removed = backend.rmdir(path: dstPath)
                default:
                    removed = backend.unlink(path: dstPath)
                }
                if !removed {
                    throw Self.posixError(from: backend)
                }
            }
        }

        guard backend.rename(src: srcPath, dst: dstPath) else {
            throw Self.posixError(from: backend)
        }
        return destinationName
    }

    // MARK: - Sync (async)

    func synchronize(flags: FSSyncFlags) async throws {
        // The backend's flush is a no-op while writes go straight to the
        // device, but we still call it so that future batching backends
        // can hook here without a contract change.
        _ = backend.flush()
    }

    // MARK: - PathConfOperations

    var maximumLinkCount: Int { 65000 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }

    // MARK: - Helpers

    static func fsItemType(from backendType: BackendFileType) -> FSItem.ItemType {
        switch backendType {
        case .file:        return .file
        case .directory:   return .directory
        case .symlink:     return .symlink
        case .charDevice:  return .charDevice
        case .blockDevice: return .blockDevice
        case .fifo:        return .fifo
        case .socket:      return .socket
        case .unknown:     return .file
        }
    }

    /// Build an `FSItem.Attributes` snapshot from a backend stat. Used by
    /// `setAttributes` to return the post-mutation state without
    /// duplicating field-by-field plumbing.
    static func attributes(from attr: BackendFileAttributes) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.type = fsItemType(from: attr.fileType)
        attrs.mode = UInt32(attr.mode & 0o7777)
        attrs.uid = uid_t(attr.uid)
        attrs.gid = gid_t(attr.gid)
        attrs.size = attr.size
        attrs.linkCount = UInt32(attr.linkCount)
        attrs.allocSize = attr.size
        attrs.accessTime = timespec(tv_sec: Int(attr.atime), tv_nsec: 0)
        attrs.modifyTime = timespec(tv_sec: Int(attr.mtime), tv_nsec: 0)
        attrs.changeTime = timespec(tv_sec: Int(attr.ctime), tv_nsec: 0)
        if attr.crtime > 0 {
            attrs.addedTime = timespec(tv_sec: Int(attr.crtime), tv_nsec: 0)
        }
        if let id = FSItem.Identifier(rawValue: attr.fileID) {
            attrs.fileID = id
        }
        return attrs
    }

    /// Translate the backend's last errno into a `POSIXError` we can throw
    /// from FSKit-facing methods. Defaults to EIO when the errno is
    /// missing or doesn't map to a known POSIXErrorCode.
    static func posixError(from backend: FileSystemBackend) -> POSIXError {
        let raw = backend.lastErrno()
        if raw != 0, let code = POSIXErrorCode(rawValue: raw) {
            return POSIXError(code)
        }
        return POSIXError(.EIO)
    }

    /// Join a parent directory path to a child name, taking care to avoid
    /// the double-slash "//foo" trap when the parent is the root.
    static func joinPath(_ parent: String, _ child: String) -> String {
        return parent == "/" ? "/\(child)" : "\(parent)/\(child)"
    }
}
