/*
 * XfsVolume.swift — FSKit volume for XFS (read-only).
 *
 * Implements FSVolume.Operations + FSVolume.ReadWriteOperations +
 * FSVolume.PathConfOperations. This extension is read-only, so every
 * mutating op returns EROFS — the errno for a read-only filesystem, not
 * the filesystem of that name; reads/lookups/enumeration dispatch to the
 * fs_xfs_* C ABI. XFS inode numbers are 64-bit, so item identity is
 * UInt64 (XfsItem / XfsTag).
 *
 * MIT License — see LICENSE
 */

import FSKit
import Foundation
import os
import DiskJockeyLibrary

final class XfsVolume: FSVolume,
                         FSVolume.Operations,
                         FSVolume.ReadWriteOperations,
                         FSVolume.PathConfOperations {

    private var bridgeFS: OpaquePointer?
    private var contextPtr: UnsafeMutableRawPointer?
    private let bsdName: String
    private let stats: IOStatsCollector
    private let items = FileIDCache<XfsItem>()

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

    private func item(forInode inode: UInt64, path: VolumePath,
                      parentInode: UInt64?) -> XfsItem {
        items.getOrCreate(
            id: inode,
            validate: { $0.volumePath == path && $0.parentInode == parentInode },
            create: { XfsItem(inode: inode, volumePath: path, parentInode: parentInode) }
        )
    }

    /// How the pinned driver reads a path: am-fs-xfs 0.8.0 decodes it as UTF-8
    /// (rust-fs-xfs#269 made it byte-exact, unreleased). A name that is not
    /// UTF-8 is still listed under its real bytes, but is refused here
    /// rather than handed to a driver that cannot resolve it. Becomes
    /// `.bytes` when the bundle moves to a byte-exact release
    /// (diskjockey#219).
    static let pathEncoding: DriverPathEncoding = .utf8

    // MARK: - Capabilities

    /// The name `statfs` reports, and the one place it is spelled.
    static let fsTypeName = "xfs"

    /// XFS is journalled. This was `false` once, inherited from the
    /// EROFS volume this file was copied from — which is why it is a
    /// parameter now rather than nine assignments repeated per
    /// filesystem. See ReadOnlyVolumeCapabilities.
    static let readOnlyCapabilities = ReadOnlyVolumeCapabilities(hasJournal: true)

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        Self.readOnlyCapabilities.fsCapabilities
    }

    var volumeStatistics: FSStatFSResult {
        guard let fs = bridgeFS else {
            return FSStatFSResult(fileSystemTypeName: Self.fsTypeName)
        }
        var info = fs_xfs_volume_info_t()
        fs_xfs_get_volume_info(fs, &info)
        // XFS counts blocks, so the figures pass straight through. The
        // free counts are not reported by the driver; zero is what the
        // field means when it is unknown.
        let shared = ReadOnlyVolumeInfo(
            capacity: .blocks(blockSize: UInt64(info.block_size),
                              total: UInt64(info.total_blocks),
                              free: 0),
            ioSize: UInt64(info.block_size),
            totalInodes: info.inode_count,
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
            fs_xfs_umount(fs)
            bridgeFS = nil
        }
    }

    func activate(options: FSTaskOptions) async throws -> FSItem {
        log.info("volume: activate", scope: AppLogScope.lifecycle)
        guard let fs = bridgeFS else { throw POSIXError(.EIO) }
        var attr = fs_xfs_attr_t()
        let rootInode: UInt64 = (fs_xfs_stat(fs, "/", &attr) == 0) ? attr.inode : 1
        return item(forInode: rootInode, path: .root, parentInode: nil)
    }

    func deactivate(options: FSDeactivateOptions) async throws {
        log.info("volume: deactivate", scope: AppLogScope.lifecycle)
        stats.stop()
        if let fs = bridgeFS {
            fs_xfs_umount(fs)
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
        guard let fs = bridgeFS, let eItem = item as? XfsItem else {
            throw POSIXError(.EBADF)
        }
        var attr = fs_xfs_attr_t()
        guard eItem.volumePath.withCString({ fs_xfs_stat(fs, $0, &attr) }) == 0 else {
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
        guard let fs = bridgeFS, let dirItem = directory as? XfsItem else {
            throw POSIXError(.EBADF)
        }
        // By the name's bytes, not its String: `name.string` is nil for a
        // name that is not UTF-8, and FSKit requires such a name to be
        // looked up all the same (diskjockey#219).
        let childPath = try dirItem.volumePath.child(name, for: Self.pathEncoding)

        var attr = fs_xfs_attr_t()
        guard childPath.withCString({ fs_xfs_stat(fs, $0, &attr) }) == 0 else {
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
        guard let fs = bridgeFS, let dirItem = directory as? XfsItem else {
            throw POSIXError(.EBADF)
        }
        guard let iter = dirItem.volumePath.withCString({ fs_xfs_dir_open(fs, $0) }) else {
            throw POSIXError(.EIO)
        }
        defer { fs_xfs_dir_close(iter) }

        var entryCookie: UInt64 = 1
        let startCookie = cookie.rawValue

        while let de = fs_xfs_dir_next(iter) {
            if entryCookie <= startCookie {
                entryCookie += 1
                continue
            }
            // The name's bytes, bounded by the array rather than a hand-
            // written capacity (diskjockey#207), and never decoded: a
            // String repairs invalid UTF-8 to U+FFFD, which shows the
            // wrong name and merges distinct ones (diskjockey#219).
            guard let nameBytes = DirentName.bytes(of: de.pointee.name) else {
                throw POSIXError(.EIO)
            }
            let fsName = DirentName.fileName(nameBytes)
            // Nil when the pinned driver could not resolve the child; the
            // entry is still listed, without attributes.
            let childPath = try? dirItem.volumePath.child(nameBytes, for: Self.pathEncoding)
            let fileType = Self.fsItemType(fromRaw: UInt32(de.pointee.file_type))

            var itemAttrs: FSItem.Attributes? = nil
            if attributes != nil {
                var attr = fs_xfs_attr_t()
                if let childPath, childPath.withCString({ fs_xfs_stat(fs, $0, &attr) }) == 0 {
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
        if let eItem = item as? XfsItem {
            items.remove(id: eItem.inode)
        }
    }

    // MARK: - Symlink

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        guard let fs = bridgeFS, let eItem = item as? XfsItem else {
            throw POSIXError(.EBADF)
        }
        // Success is the target's length, not zero (see SymlinkTarget).
        // A target is a path, and a path is bytes (diskjockey#219).
        let target = try eItem.volumePath.withCString { path in
            try SymlinkTarget.readBytes(
                lastErrno: { Int32(fs_xfs_last_errno()) }
            ) { buf, size in
                fs_xfs_readlink(fs, path, buf, size)
            }
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
        guard let fs = bridgeFS, let eItem = item as? XfsItem else {
            throw POSIXError(.EBADF)
        }
        return eItem.volumePath.withCString { path in
            buffer.withUnsafeMutableBytes { rawBuf in
                let n = fs_xfs_read_file(
                    fs, path, rawBuf.baseAddress, UInt64(offset), UInt64(length))
                return max(0, Int(n))
            }
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

    /// XFS's on-disk file-type codes. Kept here because the numbers
    /// are XFS's; the mapping onto FSKit is shared.
    static func readOnlyFileType(fromRaw raw: UInt32) -> ReadOnlyFileType {
        switch raw {
        case 1: return .file        // FS_XFS_FT_REG_FILE
        case 2: return .directory   // FS_XFS_FT_DIR
        case 7: return .symlink     // FS_XFS_FT_SYMLINK
        default: return .other
        }
    }

    static func fsItemType(fromRaw raw: UInt32) -> FSItem.ItemType {
        readOnlyFileType(fromRaw: raw).fsItemType
    }

    static func attributes(from attr: fs_xfs_attr_t,
                           parentInode: UInt64?) -> FSItem.Attributes {
        ReadOnlyVolumeSupport.fsAttributes(
            from: ReadOnlyFileAttributes(
                inode: attr.inode,
                mode: UInt32(attr.mode),
                uid: attr.uid,
                gid: attr.gid,
                size: attr.size,
                linkCount: attr.link_count,
                mtime: Int64(attr.mtime),
                fileType: readOnlyFileType(fromRaw: attr.file_type)),
            parentInode: parentInode)
    }
}
