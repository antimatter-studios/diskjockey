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

    /// Track items by file ID for reclamation
    private var items: [UInt64: EXT4Item] = [:]
    private let itemsLock = NSLock()

    init(volumeID: FSVolume.Identifier,
         volumeName: FSFileName,
         backend: FileSystemBackend,
         blockDeviceContext: UnsafeMutableRawPointer? = nil) {
        self.backend = backend
        self.blockDeviceContext = blockDeviceContext
        super.init(volumeID: volumeID, volumeName: volumeName)
    }

    // MARK: - Item management

    private func item(forID fileID: UInt64, path: String) -> EXT4Item {
        itemsLock.lock()
        defer { itemsLock.unlock() }

        if let existing = items[fileID] {
            return existing
        }

        let newItem = EXT4Item(inode: UInt32(fileID), path: path)
        items[fileID] = newItem
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
        logger.error("volume: mount")
    }

    func unmount() async {
        logger.error("volume: unmount")
        backend.shutdown()
    }

    // MARK: - Activate/Deactivate (async)

    func activate(options: FSTaskOptions) async throws -> FSItem {
        logger.error("volume: activate")
        return item(forID: 2, path: "/")
    }

    func deactivate(options: FSDeactivateOptions) async throws {
        logger.error("volume: deactivate")
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
        throw POSIXError(.EROFS)
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
        logger.error("enumerateDirectory path=\(dirItem.path, privacy: .public) cookie=\(cookie.rawValue) attrsReq=\(attributes != nil)")

        guard let entries = backend.readDirectory(path: dirItem.path) else {
            throw POSIXError(.EIO)
        }

        // Log all entries so we can inspect the data regardless of Finder's handling.
        for (i, e) in entries.enumerated() {
            logger.error("  entry[\(i)] name=\(e.name, privacy: .public) fileID=\(e.fileID) fileType=\(String(describing: e.fileType), privacy: .public)")
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

        logger.error("enumerateDirectory done: packed=\(packedCount) total=\(entries.count) stopped=\(stopped)")
        return FSDirectoryVerifier(rawValue: UInt64(entries.count + 1))
    }

    // MARK: - Reclaim (async)

    func reclaimItem(_ item: FSItem) async throws {
        if let ext4Item = item as? EXT4Item {
            let key = UInt64(ext4Item.inode)
            itemsLock.lock()
            items.removeValue(forKey: key)
            itemsLock.unlock()
        }
    }

    // MARK: - File read/write (async)

    func write(contents data: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        throw POSIXError(.EROFS)
    }

    func read(from item: FSItem, at offset: off_t, length: Int,
              into buffer: FSMutableFileDataBuffer) async throws -> Int {
        guard let ext4Item = item as? EXT4Item else {
            throw POSIXError(.EBADF)
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
            logger.error("read(from: \(ext4Item.path, privacy: .public)): backend returned \(bytesRead)")
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

    // MARK: - Read-only stubs (async)

    func createItem(named name: FSFileName, type: FSItem.ItemType,
                    inDirectory directory: FSItem,
                    attributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        throw POSIXError(.EROFS)
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                            attributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) {
        throw POSIXError(.EROFS)
    }

    func createLink(to item: FSItem, named name: FSFileName,
                    inDirectory directory: FSItem) async throws -> FSFileName {
        throw POSIXError(.EROFS)
    }

    func removeItem(_ item: FSItem, named name: FSFileName,
                    fromDirectory directory: FSItem) async throws {
        throw POSIXError(.EROFS)
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem,
                    named sourceName: FSFileName, to destinationName: FSFileName,
                    inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?) async throws -> FSFileName {
        throw POSIXError(.EROFS)
    }

    // MARK: - Sync (async)

    func synchronize(flags: FSSyncFlags) async throws {
        // Read-only, nothing to sync
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
}
