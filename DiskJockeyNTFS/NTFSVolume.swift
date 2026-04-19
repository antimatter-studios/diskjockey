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

    /// Track items by file record number for reclamation
    private var items: [UInt64: NTFSItem] = [:]
    private let itemsLock = NSLock()

    init(volumeID: FSVolume.Identifier,
         volumeName: FSFileName,
         bridgeFS: OpaquePointer,
         blockDevice: FSBlockDeviceResource) {
        self.bridgeFS = bridgeFS
        self.blockDevice = blockDevice
        super.init(volumeID: volumeID, volumeName: volumeName)
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
        log.info("volume: mount")
    }

    func unmount() async {
        log.info("volume: unmount")
        if let fs = bridgeFS {
            fs_ntfs_umount(fs)
            bridgeFS = nil
        }
    }

    // MARK: - Activate/Deactivate

    func activate(options: FSTaskOptions) async throws -> FSItem {
        log.info("volume: activate")
        return item(forRecordNumber: 5, path: "/")
    }

    func deactivate(options: FSDeactivateOptions) async throws {
        log.info("volume: deactivate")
        if let fs = bridgeFS {
            fs_ntfs_umount(fs)
            bridgeFS = nil
        }
    }

    // MARK: - File attributes

    func attributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem
    ) async throws -> FSItem.Attributes {
        guard let fs = bridgeFS, let ntfsItem = item as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
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
        throw fs_errorForPOSIXError(EROFS)
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

    // MARK: - Read-only stubs

    func createItem(
        named name: FSFileName, type: FSItem.ItemType,
        inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest
    ) async throws -> (FSItem, FSFileName) {
        throw fs_errorForPOSIXError(EROFS)
    }

    func createSymbolicLink(
        named name: FSFileName, inDirectory directory: FSItem,
        attributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName
    ) async throws -> (FSItem, FSFileName) {
        throw fs_errorForPOSIXError(EROFS)
    }

    func createLink(
        to item: FSItem, named name: FSFileName, inDirectory directory: FSItem
    ) async throws -> FSFileName {
        throw fs_errorForPOSIXError(EROFS)
    }

    func removeItem(
        _ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem
    ) async throws {
        throw fs_errorForPOSIXError(EROFS)
    }

    func renameItem(
        _ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
        to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?
    ) async throws -> FSFileName {
        throw fs_errorForPOSIXError(EROFS)
    }

    // MARK: - Sync

    func synchronize(flags: FSSyncFlags) async throws {
    }

    // MARK: - ReadWriteOperations

    func read(
        from item: FSItem, at offset: off_t, length: Int,
        into buffer: FSMutableFileDataBuffer
    ) async throws -> Int {
        guard let fs = bridgeFS, let ntfsItem = item as? NTFSItem else {
            throw fs_errorForPOSIXError(EBADF)
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
        contents: Data, to item: FSItem, at offset: off_t
    ) async throws -> Int {
        throw fs_errorForPOSIXError(EROFS)
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
}
