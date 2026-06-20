/*
 * ErofsVolume.swift — FSKit volume for EROFS (read-only).
 *
 * Mirror of DiskJockeySQUASHFS's volume. Implements FSVolume.Operations +
 * FSVolume.ReadWriteOperations + FSVolume.PathConfOperations. EROFS is
 * read-only, so every mutating op returns EROFS; reads/lookups/enumeration
 * dispatch to the fs_erofs_* C ABI. EROFS NIDs are 64-bit, so item identity
 * is UInt64 (ErofsItem / ErofsTag).
 *
 * MIT License — see LICENSE
 */

import FSKit
import Foundation
import os
import DiskJockeyLibrary

final class ErofsVolume: FSVolume,
                         FSVolume.Operations,
                         FSVolume.ReadWriteOperations,
                         FSVolume.PathConfOperations {

    private var bridgeFS: OpaquePointer?
    private let blockDevice: FSBlockDeviceResource
    private var contextPtr: UnsafeMutableRawPointer?
    private let bsdName: String
    private let stats: IOStatsCollector
    private let items = FileIDCache<ErofsItem>()

    init(volumeID: FSVolume.Identifier,
         volumeName: FSFileName,
         bridgeFS: OpaquePointer,
         blockDevice: FSBlockDeviceResource,
         contextPtr: UnsafeMutableRawPointer,
         bsdName: String,
         stats: IOStatsCollector) {
        self.bridgeFS = bridgeFS
        self.blockDevice = blockDevice
        self.contextPtr = contextPtr
        self.bsdName = bsdName
        self.stats = stats
        super.init(volumeID: volumeID, volumeName: volumeName)
    }

    // MARK: - Item cache

    private func item(forInode inode: UInt64, path: String,
                      parentInode: UInt64?) -> ErofsItem {
        items.getOrCreate(
            id: inode,
            validate: { $0.path == path && $0.parentInode == parentInode },
            create: { ErofsItem(inode: inode, path: path, parentInode: parentInode) }
        )
    }

    // MARK: - Capabilities

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsPersistentObjectIDs = true
        caps.supportsSymbolicLinks = true
        caps.supportsHardLinks = false
        caps.supportsJournal = false
        caps.supportsActiveJournal = false
        caps.supportsSparseFiles = true
        caps.supports2TBFiles = true
        // EROFS NIDs are 64-bit.
        caps.supports64BitObjectIDs = true
        // EROFS (Linux) is case-sensitive.
        caps.caseFormat = .sensitive
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: "erofs")
        guard let fs = bridgeFS else { return result }
        var info = fs_erofs_volume_info_t()
        fs_erofs_get_volume_info(fs, &info)
        let bs = Int(info.block_size)
        result.blockSize = bs
        result.ioSize = bs
        result.totalBlocks = UInt64(info.total_blocks)
        result.availableBlocks = 0
        result.freeBlocks = 0
        result.totalFiles = info.inode_count
        result.freeFiles = 0
        return result
    }

    // MARK: - Lifecycle

    func mount(options: FSTaskOptions) async throws {
        log.info("volume: mount", scope: AppLogScope.lifecycle)
    }

    func unmount() async {
        log.info("volume: unmount", scope: AppLogScope.lifecycle)
        if let fs = bridgeFS {
            fs_erofs_umount(fs)
            bridgeFS = nil
        }
    }

    func activate(options: FSTaskOptions) async throws -> FSItem {
        log.info("volume: activate", scope: AppLogScope.lifecycle)
        guard let fs = bridgeFS else { throw POSIXError(.EIO) }
        var attr = fs_erofs_attr_t()
        let rootInode: UInt64 = (fs_erofs_stat(fs, "/", &attr) == 0) ? attr.inode : 1
        return item(forInode: rootInode, path: "/", parentInode: nil)
    }

    func deactivate(options: FSDeactivateOptions) async throws {
        log.info("volume: deactivate", scope: AppLogScope.lifecycle)
        stats.stop()
        if let fs = bridgeFS {
            fs_erofs_umount(fs)
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
        guard let fs = bridgeFS, let eItem = item as? ErofsItem else {
            throw POSIXError(.EBADF)
        }
        var attr = fs_erofs_attr_t()
        guard fs_erofs_stat(fs, eItem.path, &attr) == 0 else {
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
        guard let fs = bridgeFS, let dirItem = directory as? ErofsItem else {
            throw POSIXError(.EBADF)
        }
        guard let nameStr = name.string else { throw POSIXError(.EINVAL) }
        let childPath = Self.joinPath(dirItem.path, nameStr)

        var attr = fs_erofs_attr_t()
        guard fs_erofs_stat(fs, childPath, &attr) == 0 else {
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
        guard let fs = bridgeFS, let dirItem = directory as? ErofsItem else {
            throw POSIXError(.EBADF)
        }
        guard let iter = fs_erofs_dir_open(fs, dirItem.path) else {
            throw POSIXError(.EIO)
        }
        defer { fs_erofs_dir_close(iter) }

        var entryCookie: UInt64 = 1
        let startCookie = cookie.rawValue

        while let de = fs_erofs_dir_next(iter) {
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
                var attr = fs_erofs_attr_t()
                if fs_erofs_stat(fs, childPath, &attr) == 0 {
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
        if let eItem = item as? ErofsItem {
            items.remove(id: eItem.inode)
        }
    }

    // MARK: - Symlink

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        guard let fs = bridgeFS, let eItem = item as? ErofsItem else {
            throw POSIXError(.EBADF)
        }
        var buf = [CChar](repeating: 0, count: 4096)
        guard fs_erofs_readlink(fs, eItem.path, &buf, buf.count) == 0 else {
            throw POSIXError(.EIO)
        }
        return FSFileName(string: String(cString: buf))
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
        guard let fs = bridgeFS, let eItem = item as? ErofsItem else {
            throw POSIXError(.EBADF)
        }
        return buffer.withUnsafeMutableBytes { rawBuf in
            let n = fs_erofs_read_file(
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
        case 1: return .file        // FS_EROFS_FT_REG_FILE
        case 2: return .directory   // FS_EROFS_FT_DIR
        case 7: return .symlink     // FS_EROFS_FT_SYMLINK
        default: return .file
        }
    }

    static func joinPath(_ parent: String, _ child: String) -> String {
        parent == "/" ? "/\(child)" : "\(parent)/\(child)"
    }

    static func attributes(from attr: fs_erofs_attr_t,
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
