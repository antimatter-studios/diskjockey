/*
 * BtrfsVolume.swift — FSKit volume for BTRFS (read-only).
 *
 * Implements FSVolume.Operations + FSVolume.ReadWriteOperations +
 * FSVolume.PathConfOperations. This extension is read-only, so every
 * mutating op returns EROFS — the errno for a read-only filesystem, not
 * the filesystem of that name; reads/lookups/enumeration dispatch to the
 * fs_btrfs_* C ABI. Btrfs inode numbers are 64-bit, so item identity is
 * UInt64 (BtrfsItem / BtrfsTag).
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

    private var bridgeFS: OpaquePointer?
    private var contextPtr: UnsafeMutableRawPointer?
    private let bsdName: String
    private let stats: IOStatsCollector
    private let items = FileIDCache<BtrfsItem>()

    init(volumeID: FSVolume.Identifier,
         volumeName: FSFileName,
         bridgeFS: OpaquePointer,
         contextPtr: UnsafeMutableRawPointer,
         bsdName: String,
         stats: IOStatsCollector) {
        self.bridgeFS = bridgeFS
        self.contextPtr = contextPtr
        self.bsdName = bsdName
        self.stats = stats
        super.init(volumeID: volumeID, volumeName: volumeName)
    }

    // MARK: - Item cache

    private func item(forInode inode: UInt64, path: String,
                      parentInode: UInt64?) -> BtrfsItem {
        items.getOrCreate(
            id: inode,
            validate: { $0.path == path && $0.parentInode == parentInode },
            create: { BtrfsItem(inode: inode, path: path, parentInode: parentInode) }
        )
    }

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
        guard let fs = bridgeFS else {
            return FSStatFSResult(fileSystemTypeName: Self.fsTypeName)
        }
        var info = fs_btrfs_volume_info_t()
        fs_btrfs_get_volume_info(fs, &info)
        // Btrfs reports capacity in BYTES rather than blocks, advertises
        // its node size for I/O rather than its sector size, and has no
        // fixed inode table — inodes come from the same pool as data, so
        // there is no total or free count to give. The nil inode counts
        // say that; see ReadOnlyVolumeInfo.
        let shared = ReadOnlyVolumeInfo(
            capacity: .bytes(sectorSize: UInt64(info.sector_size),
                             total: info.total_bytes,
                             used: info.bytes_used),
            ioSize: UInt64(info.node_size),
            totalInodes: nil,
            freeInodes: nil)
        return ReadOnlyVolumeSupport.statFS(shared, fileSystemTypeName: Self.fsTypeName)
    }

    // MARK: - Lifecycle

    func mount(options: FSTaskOptions) async throws {
        log.info("volume: mount", scope: AppLogScope.lifecycle)
    }

    func unmount() async {
        log.info("volume: unmount", scope: AppLogScope.lifecycle)
        if let fs = bridgeFS {
            fs_btrfs_umount(fs)
            bridgeFS = nil
        }
    }

    func activate(options: FSTaskOptions) async throws -> FSItem {
        log.info("volume: activate", scope: AppLogScope.lifecycle)
        guard let fs = bridgeFS else { throw POSIXError(.EIO) }
        var attr = fs_btrfs_attr_t()
        let rootInode: UInt64 = (fs_btrfs_stat(fs, "/", &attr) == 0) ? attr.inode : 1
        return item(forInode: rootInode, path: "/", parentInode: nil)
    }

    func deactivate(options: FSDeactivateOptions) async throws {
        log.info("volume: deactivate", scope: AppLogScope.lifecycle)
        stats.stop()
        if let fs = bridgeFS {
            fs_btrfs_umount(fs)
            bridgeFS = nil
        }
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
        guard let fs = bridgeFS, let eItem = item as? BtrfsItem else {
            throw POSIXError(.EBADF)
        }
        var attr = fs_btrfs_attr_t()
        guard fs_btrfs_stat(fs, eItem.path, &attr) == 0 else {
            throw POSIXError(.ENOENT)
        }
        return Self.attributes(from: attr, parentInode: eItem.parentInode)
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
        guard let fs = bridgeFS, let dirItem = directory as? BtrfsItem else {
            throw POSIXError(.EBADF)
        }
        guard let nameStr = name.string else { throw POSIXError(.EINVAL) }
        let childPath = Self.joinPath(dirItem.path, nameStr)

        var attr = fs_btrfs_attr_t()
        guard fs_btrfs_stat(fs, childPath, &attr) == 0 else {
            throw POSIXError(.ENOENT)
        }
        let found = item(forInode: attr.inode, path: childPath, parentInode: dirItem.inode)
        return (found, name)
    }

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker
    ) async throws -> FSDirectoryVerifier {
        guard let fs = bridgeFS, let dirItem = directory as? BtrfsItem else {
            throw POSIXError(.EBADF)
        }
        guard let iter = fs_btrfs_dir_open(fs, dirItem.path) else {
            throw POSIXError(.EIO)
        }
        defer { fs_btrfs_dir_close(iter) }

        var entryCookie: UInt64 = 1
        let startCookie = cookie.rawValue

        while let de = fs_btrfs_dir_next(iter) {
            if entryCookie <= startCookie {
                entryCookie += 1
                continue
            }
            let entryName = withUnsafePointer(to: de.pointee.name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            let fsName = FSFileName(string: entryName)
            let childPath = Self.joinPath(dirItem.path, entryName)
            let fileType = Self.fsItemType(fromRaw: UInt32(de.pointee.file_type))

            var itemAttrs: FSItem.Attributes? = nil
            if attributes != nil {
                var attr = fs_btrfs_attr_t()
                if fs_btrfs_stat(fs, childPath, &attr) == 0 {
                    itemAttrs = Self.attributes(from: attr, parentInode: dirItem.inode)
                }
            }

            let packed = packer.packEntry(
                name: fsName,
                itemType: fileType,
                itemID: FSItem.Identifier(rawValue: de.pointee.inode)!,
                nextCookie: FSDirectoryCookie(rawValue: entryCookie),
                attributes: itemAttrs
            )
            if !packed { break }
            entryCookie += 1
        }
        return FSDirectoryVerifier(rawValue: entryCookie)
    }

    func reclaimItem(_ item: FSItem) async throws {
        if let eItem = item as? BtrfsItem {
            items.remove(id: eItem.inode)
        }
    }

    // MARK: - Symlink

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        guard let fs = bridgeFS, let eItem = item as? BtrfsItem else {
            throw POSIXError(.EBADF)
        }
        // Success is the target's length, not zero (see SymlinkTarget).
        let target = try SymlinkTarget.read(
            lastErrno: { Int32(fs_btrfs_last_errno()) }
        ) { buf, size in
            fs_btrfs_readlink(fs, eItem.path, buf, size)
        }
        return FSFileName(string: target)
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
            let n = try readImpl(from: item, at: offset, length: length, into: buffer)
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
    ) throws -> Int {
        guard let fs = bridgeFS, let eItem = item as? BtrfsItem else {
            throw POSIXError(.EBADF)
        }
        return buffer.withUnsafeMutableBytes { rawBuf in
            let n = fs_btrfs_read_file(
                fs, eItem.path, rawBuf.baseAddress, UInt64(offset), UInt64(length))
            return max(0, Int(n))
        }
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

    static func fsItemType(fromRaw raw: UInt32) -> FSItem.ItemType {
        switch raw {
        case 1: return .file        // FS_BTRFS_FT_REG_FILE
        case 2: return .directory   // FS_BTRFS_FT_DIR
        case 7: return .symlink     // FS_BTRFS_FT_SYMLINK
        default: return .file
        }
    }

    static func joinPath(_ parent: String, _ child: String) -> String {
        parent == "/" ? "/\(child)" : "\(parent)/\(child)"
    }

    static func attributes(from attr: fs_btrfs_attr_t,
                           parentInode: UInt64?) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.type = fsItemType(fromRaw: attr.file_type)
        attrs.mode = UInt32(attr.mode)
        attrs.uid = attr.uid
        attrs.gid = attr.gid
        attrs.flags = 0
        attrs.size = attr.size
        attrs.allocSize = attr.size
        attrs.linkCount = attr.link_count
        let ts = timespec(tv_sec: Int(attr.mtime), tv_nsec: 0)
        attrs.accessTime = ts
        attrs.modifyTime = ts
        attrs.changeTime = ts
        attrs.birthTime = ts
        if let id = FSItem.Identifier(rawValue: attr.inode) {
            attrs.fileID = id
        }
        let parentRaw = parentInode ?? 1
        if let parentID = FSItem.Identifier(rawValue: parentRaw) {
            attrs.parentID = parentID
        }
        return attrs
    }
}
