/*
 * BtrfsVolume.swift — FSKit volume for BTRFS (read-only).
 *
 * Implements FSVolume.Operations + FSVolume.ReadWriteOperations +
 * FSVolume.PathConfOperations. This extension is read-only, so every
 * mutating op returns EROFS — the errno for a read-only filesystem, not
 * the filesystem of that name; reads/lookups/enumeration dispatch to the
 * driver. An item's identity is its (tree, inode) pair packed into
 * FSKit's 64-bit identifier by BtrfsIdentifierSpace, because a Btrfs inode
 * number is unique only within one subvolume (diskjockey#261; the design is
 * in DiskJockeyLibrary/BtrfsItemIdentity.swift).
 *
 * The driver is a ReadOnlyVolumeDriver rather than the fs_btrfs_* C ABI
 * itself: BtrfsDriver.swift makes those calls, and this file makes none, so
 * it builds in DiskJockeyBTRFSCore and `swift test` runs it
 * (diskjockey#196).
 *
 * MIT License — see LICENSE
 */

import FSKit
import Foundation
import os
import DiskJockeyLibrary

final class BtrfsVolume: FSVolume,
                         FSVolume.Operations,
                         FSVolume.ReadWriteOperations,
                         FSVolume.PathConfOperations {

    private var driver: ReadOnlyVolumeDriver?
    private var contextPtr: UnsafeMutableRawPointer?
    private let bsdName: String
    private let stats: IOStatsCollector
    /// Keyed on the packed (tree, inode) identifier, so two subvolumes'
    /// same-numbered inodes are two entries rather than one evicting the
    /// other (diskjockey#261).
    private let items = FileIDCache<BtrfsItem>()
    private let ids = BtrfsIdentifierSpace()

    init(volumeID: FSVolume.Identifier,
         volumeName: FSFileName,
         driver: ReadOnlyVolumeDriver,
         contextPtr: UnsafeMutableRawPointer?,
         bsdName: String,
         stats: IOStatsCollector) {
        self.driver = driver
        self.contextPtr = contextPtr
        self.bsdName = bsdName
        self.stats = stats
        super.init(volumeID: volumeID, volumeName: volumeName)
    }

    // MARK: - Item cache

    func item(for key: BtrfsObjectKey, path: VolumePath,
              parentFileID: UInt64?) throws -> BtrfsItem {
        let fileID = try ids.fileID(for: key)
        return items.getOrCreate(
            id: fileID,
            validate: { $0.volumePath == path && $0.parentFileID == parentFileID },
            create: { BtrfsItem(fileID: fileID, volumePath: path, parentFileID: parentFileID) }
        )
    }

    /// The tree a directory item's entries belong to.
    private func tree(of directory: BtrfsItem) throws -> BtrfsTree {
        try ids.key(forFileID: directory.fileID).tree
    }

    /// The tree id of the subvolume `name` in `directory` names, or nil if
    /// the entry is not a subvolume. Lists the directory, so it is asked
    /// only when a lookup has crossed a subvolume boundary.
    private func subvolumeEntry(named name: [UInt8], in directory: VolumePath,
                                driver: ReadOnlyVolumeDriver) -> UInt64? {
        var tree: UInt64? = nil
        _ = driver.walkDirectory(directory) { entry in
            guard entry.name == name else { return true }
            tree = entry.isSubvolume ? entry.inode : nil
            return false
        }
        return tree
    }

    /// How the pinned driver reads a path: am-fs-btrfs 0.8.0 takes it byte
    /// for byte (rust-fs-btrfs#214), so a name that is not UTF-8 resolves
    /// under the same bytes its dirent reported. Earlier releases decoded it
    /// as UTF-8; scripts/tests/path-encoding-matches-pin.sh fails a `.bytes`
    /// declaration over one of those (diskjockey#254).
    static let pathEncoding: DriverPathEncoding = .bytes

    // MARK: - Capabilities

    /// The name `statfs` reports, and the one place it is spelled.
    static let fsTypeName = "btrfs"

    /// Btrfs is journalled. `supportsActiveJournal` stays false: this
    /// driver refuses a filesystem with a dirty log rather than
    /// replaying one, so the log tree is never active from here.
    static let readOnlyCapabilities = ReadOnlyVolumeCapabilities(hasJournal: true)

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        Self.readOnlyCapabilities.fsCapabilities
    }

    var volumeStatistics: FSStatFSResult {
        guard let info = driver?.volumeInfo() else {
            return FSStatFSResult(fileSystemTypeName: Self.fsTypeName)
        }
        return ReadOnlyVolumeSupport.statFS(info, fileSystemTypeName: Self.fsTypeName)
    }

    // MARK: - Lifecycle

    func mount(options: FSTaskOptions) async throws {
        log.info("volume: mount", scope: AppLogScope.lifecycle)
    }

    func unmount() async {
        log.info("volume: unmount", scope: AppLogScope.lifecycle)
        driver?.unmount()
        driver = nil
    }

    func activate(options: FSTaskOptions) async throws -> FSItem {
        log.info("volume: activate", scope: AppLogScope.lifecycle)
        return try rootItem()
    }

    /// The body of `activate`, which a test can call: FSTaskOptions has
    /// no public initialiser.
    func rootItem() throws -> BtrfsItem {
        guard let driver else { throw POSIXError(.EIO) }
        // A root that cannot be read is a mount that failed. This fell
        // back to inode 1 once, handing FSKit a root that named nothing.
        guard let root = driver.stat(.root) else { throw driver.lastPOSIXError() }
        return try item(for: BtrfsObjectKey(tree: .mounted, inode: root.inode),
                        path: .root, parentFileID: nil)
    }

    func deactivate(options: FSDeactivateOptions) async throws {
        log.info("volume: deactivate", scope: AppLogScope.lifecycle)
        stats.stop()
        driver?.unmount()
        driver = nil
        if let ctx = contextPtr {
            Unmanaged<BlockDeviceContext>.fromOpaque(ctx).release()
            contextPtr = nil
        }
    }

    // MARK: - Attributes

    func attributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem
    ) async throws -> FSItem.Attributes {
        guard let driver, let eItem = item as? BtrfsItem else {
            throw POSIXError(.EBADF)
        }
        // The driver's own errno, not a blanket ENOENT: ENOENT tells
        // Finder the file is gone, and an I/O error has not said that.
        guard let attr = driver.stat(eItem.volumePath) else {
            throw driver.lastPOSIXError()
        }
        return Self.attributes(from: attr, fileID: eItem.fileID,
                               parentFileID: eItem.parentFileID)
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem
    ) async throws -> FSItem.Attributes {
        throw POSIXError(.EROFS)
    }

    // MARK: - Lookup / enumeration

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> (FSItem, FSFileName) {
        guard let driver, let dirItem = directory as? BtrfsItem else {
            throw POSIXError(.EBADF)
        }
        // By the name's bytes, not its String: `name.string` is nil for a
        // name that is not UTF-8, and FSKit requires such a name to be
        // looked up all the same (diskjockey#219).
        let childPath = try dirItem.volumePath.child(name, for: Self.pathEncoding)

        guard let attr = driver.stat(childPath) else {
            throw driver.lastPOSIXError()
        }
        // am-fs-btrfs 0.7.0's stat does not cross into a subvolume, so a
        // subvolume's name fails above; lookupKey's crossing branch is for
        // a driver whose stat does (see BtrfsItemIdentity.swift).
        let key = try BtrfsIdentity.lookupKey(
            inDirectoryOf: try tree(of: dirItem), statInode: attr.inode,
            subvolumeEntry: {
                self.subvolumeEntry(named: [UInt8](name.data), in: dirItem.volumePath,
                                    driver: driver)
            })
        let found = try item(for: key, path: childPath, parentFileID: dirItem.fileID)
        return (found, name)
    }

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker
    ) async throws -> FSDirectoryVerifier {
        guard let dirItem = directory as? BtrfsItem else {
            throw POSIXError(.EBADF)
        }
        let end = try entries(of: dirItem, after: cookie.rawValue,
                              withAttributes: attributes != nil) { $0.pack(into: packer) }
        return FSDirectoryVerifier(rawValue: end)
    }

    /// The body of `enumerateDirectory`, with the packer as a closure so
    /// a test can stand in for it (FSKit's packer cannot be constructed).
    /// Answers the cookie after the last entry packed.
    func entries(
        of dirItem: BtrfsItem,
        after startCookie: UInt64,
        withAttributes: Bool,
        pack: (PackableDirectoryEntry) -> Bool
    ) throws -> UInt64 {
        guard let driver else { throw POSIXError(.EBADF) }
        let dirTree = try tree(of: dirItem)

        var entryCookie: UInt64 = 1
        var identifierError: Error? = nil
        let walk = driver.walkDirectory(dirItem.volumePath) { entry in
            if entryCookie <= startCookie {
                entryCookie += 1
                return true
            }
            // An entry naming a subvolume carries a TREE id, not an inode
            // (fs_btrfs.h, `is_subvolume`). It is listed as that
            // subvolume's top directory — the item a lookup of the same
            // name arrives at — never under the raw number (diskjockey#261).
            let childID: UInt64
            do {
                childID = try ids.fileID(for: BtrfsIdentity.entryKey(
                    inDirectoryOf: dirTree, direntInode: entry.inode,
                    isSubvolume: entry.isSubvolume))
            } catch {
                identifierError = error
                return false
            }
            // Nil when the pinned driver could not resolve the child; the
            // entry is still listed, under its real bytes, without
            // attributes.
            let childPath = try? dirItem.volumePath.child(entry.name, for: Self.pathEncoding)

            var itemAttrs: FSItem.Attributes? = nil
            if withAttributes, let childPath, let attr = driver.stat(childPath) {
                itemAttrs = Self.attributes(from: attr, fileID: childID,
                                            parentFileID: dirItem.fileID)
            }

            let packed = pack(PackableDirectoryEntry(
                // The name's bytes, never decoded: a String repairs
                // invalid UTF-8 to U+FFFD, which shows the wrong name and
                // merges distinct ones (diskjockey#219).
                name: DirentName.fileName(entry.name),
                itemType: entry.fileType.fsItemType,
                itemID: FSItem.Identifier(rawValue: childID)!,
                nextCookie: FSDirectoryCookie(rawValue: entryCookie),
                attributes: itemAttrs))
            if !packed { return false }
            entryCookie += 1
            return true
        }
        // An identifier that cannot be issued ends the listing as a
        // failure, not as its end (see BtrfsIdentifierSpace.fileID).
        if let identifierError { throw identifierError }
        switch walk {
        case .finished:
            return entryCookie
        case .openFailed:
            throw driver.lastPOSIXError()
        case .failedPartway:
            // Not the end of the directory: the rest of its entries are
            // missing, and a listing that stopped here would say they do
            // not exist. An entry whose name could not be read ends here
            // too.
            throw POSIXError(.EIO)
        }
    }

    func reclaimItem(_ item: FSItem) async throws {
        if let eItem = item as? BtrfsItem {
            items.remove(id: eItem.fileID)
        }
    }

    // MARK: - Symlink

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        guard let driver, let eItem = item as? BtrfsItem else {
            throw POSIXError(.EBADF)
        }
        // Success is the target's length, not zero (see SymlinkTarget).
        // A target is a path, and a path is bytes (diskjockey#219).
        let target = try SymlinkTarget.readBytes(
            lastErrno: { driver.lastErrno() }
        ) { buf, size in
            driver.readlink(eItem.volumePath, buf, size)
        }
        return FSFileName(data: Data(target))
    }

    // MARK: - Mutating ops (all rejected — read-only)

    func createItem(
        named name: FSFileName, type: FSItem.ItemType,
        inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest
    ) async throws -> (FSItem, FSFileName) {
        throw POSIXError(.EROFS)
    }

    func createSymbolicLink(
        named name: FSFileName, inDirectory directory: FSItem,
        attributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName
    ) async throws -> (FSItem, FSFileName) {
        throw POSIXError(.EROFS)
    }

    func createLink(
        to item: FSItem, named name: FSFileName, inDirectory directory: FSItem
    ) async throws -> FSFileName {
        throw POSIXError(.EROFS)
    }

    func removeItem(
        _ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem
    ) async throws {
        throw POSIXError(.EROFS)
    }

    func renameItem(
        _ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
        to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?
    ) async throws -> FSFileName {
        throw POSIXError(.EROFS)
    }

    func synchronize(flags: FSSyncFlags) async throws {
        // Nothing to flush on a read-only volume.
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
        guard let driver, let eItem = item as? BtrfsItem else {
            throw POSIXError(.EBADF)
        }
        let n = driver.read(eItem.volumePath, at: UInt64(offset), into: buffer)
        // Negative is a failure. It was clamped to zero once, and zero
        // bytes is how FSKit learns it has reached the end of the file,
        // so a read error became a silently short copy.
        guard n >= 0 else { throw driver.lastPOSIXError() }
        return Int(n)
    }

    func write(
        contents data: Data, to item: FSItem, at offset: off_t
    ) async throws -> Int {
        throw POSIXError(.EROFS)
    }

    // MARK: - PathConfOperations

    var maximumLinkCount: Int { -1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }

    // MARK: - Helpers

    /// Btrfs's file-type codes (fs_btrfs_file_type_t). Kept here because
    /// the numbers are the driver's; the mapping onto FSKit is shared.
    static func readOnlyFileType(fromRaw raw: UInt32) -> ReadOnlyFileType {
        switch raw {
        case 1: return .file        // FS_BTRFS_FT_REGULAR
        case 2: return .directory   // FS_BTRFS_FT_DIRECTORY
        case 7: return .symlink     // FS_BTRFS_FT_SYMLINK
        default: return .other
        }
    }

    static func fsItemType(fromRaw raw: UInt32) -> FSItem.ItemType {
        readOnlyFileType(fromRaw: raw).fsItemType
    }

    /// `fileID` and `parentFileID` are the packed identifiers, not
    /// `attr.inode`: the inode alone does not say which subvolume it is in.
    static func attributes(from attr: ReadOnlyFileAttributes, fileID: UInt64,
                           parentFileID: UInt64?) -> FSItem.Attributes {
        let attrs = ReadOnlyVolumeSupport.fsAttributes(from: attr, parentInode: parentFileID)
        if let id = FSItem.Identifier(rawValue: fileID) {
            attrs.fileID = id
        }
        return attrs
    }
}
