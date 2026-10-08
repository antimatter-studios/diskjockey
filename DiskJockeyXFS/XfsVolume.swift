/*
 * XfsVolume.swift — FSKit volume for XFS.
 *
 * Implements FSVolume.Operations + FSVolume.ReadWriteOperations +
 * FSVolume.PathConfOperations. Mutating operations require explicit mount
 * policy and mounted-driver approval; read-only mounts return EROFS.
 * Writes rewrite existing bytes and set-attributes shortens a file, as far
 * as the published driver goes (diskjockey#322); unmapped operations on an
 * approved handle return ENOTSUP.
 * Reads/lookups/enumeration dispatch to the
 * driver. XFS inode numbers are 64-bit, so item identity is UInt64
 * (XfsItem / XfsTag).
 *
 * The driver is a ReadOnlyVolumeDriver rather than the fs_xfs_* C ABI
 * itself: XfsDriver.swift makes those calls, and this file makes none, so
 * it builds in DiskJockeyXFSCore and `swift test` runs it
 * (diskjockey#196).
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

    private var driver: ReadOnlyVolumeDriver?
    private var mountAccess: XfsMountAccess
    private var contextPtr: UnsafeMutableRawPointer?
    private let bsdName: String
    private let stats: IOStatsCollector
    private let items = FileIDCache<XfsItem>()

    init(volumeID: FSVolume.Identifier,
         volumeName: FSFileName,
         driver: ReadOnlyVolumeDriver,
         contextPtr: UnsafeMutableRawPointer?,
         bsdName: String,
         stats: IOStatsCollector,
         mountAccess: XfsMountAccess = .readOnly) {
        self.driver = driver
        self.mountAccess = mountAccess
        self.contextPtr = contextPtr
        self.bsdName = bsdName
        self.stats = stats
        super.init(volumeID: volumeID, volumeName: volumeName)
    }

    // MARK: - Item cache

    func item(forInode inode: UInt64, path: VolumePath,
              parentInode: UInt64?) -> XfsItem {
        items.getOrCreate(
            id: inode,
            validate: { $0.volumePath == path && $0.parentInode == parentInode },
            create: { XfsItem(inode: inode, volumePath: path, parentInode: parentInode) }
        )
    }

    /// How the pinned driver reads a path: am-fs-xfs 0.9.0 takes it byte
    /// for byte (rust-fs-xfs#269), so a name that is not UTF-8 resolves
    /// under the same bytes its dirent reported. Earlier releases decoded it
    /// as UTF-8; scripts/tests/path-encoding-matches-pin.sh fails a `.bytes`
    /// declaration over one of those (diskjockey#254).
    static let pathEncoding: DriverPathEncoding = .bytes

    // MARK: - Capabilities

    /// The name `statfs` reports, and the one place it is spelled.
    static let fsTypeName = "xfs"

    /// XFS is journalled. This was `false` once, inherited from the
    /// EROFS volume this file was copied from — which is why it is a
    /// parameter now rather than nine assignments repeated per
    /// filesystem. See ReadOnlyVolumeCapabilities.
    static let readOnlyCapabilities = ReadOnlyVolumeCapabilities(hasJournal: true)

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = Self.readOnlyCapabilities.fsCapabilities
        caps.doesNotSupportSettingFilePermissions = !allowsWrites
        return caps
    }

    var allowsWrites: Bool {
        mountAccess.allowsWrites && (driver as? XfsMountedVolumeDriver)?.isWritable == true
    }

    /// Mutating operation adapters use this same gate. Their implementation
    /// is separate from mount authorization; unsupported operations stay so.
    func requireWritableMount() throws {
        guard allowsWrites else { throw POSIXError(.EROFS) }
    }

    var volumeStatistics: FSStatFSResult {
        guard let info = driver?.volumeInfo() else {
            return FSStatFSResult(fileSystemTypeName: Self.fsTypeName)
        }
        return ReadOnlyVolumeSupport.statFS(info, fileSystemTypeName: Self.fsTypeName)
    }

    // MARK: - Lifecycle

    func mount(options: FSTaskOptions) async throws {
        try applyMountOptions(options.taskOptions)
        log.info("volume: mount", scope: AppLogScope.lifecycle)
    }

    /// FSKit can deliver mount options after load. Never upgrade a loaded
    /// read-only handle; an explicit read-only request permanently vetoes it.
    func applyMountOptions(_ options: [String]) throws {
        let flags = options.flatMap { $0.split(separator: ",").map(String.init) }
        if flags.contains("ro") || flags.contains("--rdonly") {
            mountAccess = .readOnly
        } else if XfsMountPolicy(options: options) == .readWrite {
            try requireWritableMount()
        }
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
    func rootItem() throws -> XfsItem {
        guard let driver else { throw POSIXError(.EIO) }
        // A root that cannot be read is a mount that failed. This fell
        // back to inode 1 once, handing FSKit a root that named nothing.
        guard let root = driver.stat(.root) else { throw driver.lastPOSIXError() }
        return item(forInode: root.inode, path: .root, parentInode: nil)
    }

    func deactivate(options: FSDeactivateOptions) async throws {
        log.info("volume: deactivate", scope: AppLogScope.lifecycle)
        stats.stop()
        driver?.unmount()
        driver = nil
        if let ctx = contextPtr {
            Unmanaged<XfsBlockDeviceContext>.fromOpaque(ctx).release()
            contextPtr = nil
        }
    }

    // MARK: - Attributes

    func attributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem
    ) async throws -> FSItem.Attributes {
        guard let driver, let eItem = item as? XfsItem else {
            throw POSIXError(.EBADF)
        }
        // The driver's own errno, not a blanket ENOENT: ENOENT tells
        // Finder the file is gone, and an I/O error has not said that.
        guard let attr = driver.stat(eItem.volumePath) else {
            throw driver.lastPOSIXError()
        }
        return Self.attributes(from: attr, parentInode: eItem.parentInode)
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem
    ) async throws -> FSItem.Attributes {
        try requireWritableMount()
        guard let driver = driver as? XfsMountedVolumeDriver,
              let eItem = item as? XfsItem else {
            throw POSIXError(.EBADF)
        }
        // Only a size change is mapped; mode, ownership and times are
        // #323's. A request carrying one is refused whole, before the size
        // moves, rather than half applied and reported as a failure.
        guard newAttributes.isValid(.size),
              !newAttributes.isValid(.mode), !newAttributes.isValid(.uid),
              !newAttributes.isValid(.gid), !newAttributes.isValid(.accessTime) else {
            throw POSIXError(.ENOTSUP)
        }
        // A size change moves mtime. fs_xfs_truncate stamps it in the same
        // transaction, so a requested time rides along and is consumed.
        var consumed: FSItem.Attribute = [.size]
        var modified = Self.now()
        if newAttributes.isValid(.modifyTime) {
            modified = newAttributes.modifyTime
            consumed.insert(.modifyTime)
        }
        // Growing needs allocation the published driver refuses with
        // ENOTSUP; that errno is the answer, not an approximation.
        guard driver.truncate(eItem.volumePath, to: newAttributes.size,
                              modified: modified) == 0 else {
            throw driver.lastPOSIXError()
        }
        newAttributes.consumedAttributes = consumed
        guard let attr = driver.stat(eItem.volumePath) else {
            throw driver.lastPOSIXError()
        }
        return Self.attributes(from: attr, parentInode: eItem.parentInode)
    }

    private static func now() -> timespec {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return ts
    }

    // MARK: - Lookup / enumeration

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> (FSItem, FSFileName) {
        guard let driver, let dirItem = directory as? XfsItem else {
            throw POSIXError(.EBADF)
        }
        // By the name's bytes, not its String: `name.string` is nil for a
        // name that is not UTF-8, and FSKit requires such a name to be
        // looked up all the same (diskjockey#219).
        let childPath = try dirItem.volumePath.child(name, for: Self.pathEncoding)

        guard let attr = driver.stat(childPath) else {
            throw driver.lastPOSIXError()
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
        guard let dirItem = directory as? XfsItem else {
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
        of dirItem: XfsItem,
        after startCookie: UInt64,
        withAttributes: Bool,
        pack: (PackableDirectoryEntry) -> Bool
    ) throws -> UInt64 {
        guard let driver else { throw POSIXError(.EBADF) }

        var entryCookie: UInt64 = 1
        let walk = driver.walkDirectory(dirItem.volumePath) { entry in
            if entryCookie <= startCookie {
                entryCookie += 1
                return true
            }
            // Nil when the pinned driver could not resolve the child; the
            // entry is still listed, under its real bytes, without
            // attributes.
            let childPath = try? dirItem.volumePath.child(entry.name, for: Self.pathEncoding)

            var itemAttrs: FSItem.Attributes? = nil
            if withAttributes, let childPath, let attr = driver.stat(childPath) {
                itemAttrs = Self.attributes(from: attr, parentInode: dirItem.inode)
            }

            let packed = pack(PackableDirectoryEntry(
                // The name's bytes, never decoded: a String repairs
                // invalid UTF-8 to U+FFFD, which shows the wrong name and
                // merges distinct ones (diskjockey#219).
                name: DirentName.fileName(entry.name),
                itemType: entry.fileType.fsItemType,
                itemID: FSItem.Identifier(rawValue: entry.inode)!,
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
        if let eItem = item as? XfsItem {
            items.remove(id: eItem.inode)
        }
    }

    // MARK: - Symlink

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        guard let driver, let eItem = item as? XfsItem else {
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

    // MARK: - Mutating ops (mount gate, then operation support)

    func createItem(
        named name: FSFileName, type: FSItem.ItemType,
        inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest
    ) async throws -> (FSItem, FSFileName) {
        try requireWritableMount()
        throw POSIXError(.ENOTSUP)
    }

    func createSymbolicLink(
        named name: FSFileName, inDirectory directory: FSItem,
        attributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName
    ) async throws -> (FSItem, FSFileName) {
        try requireWritableMount()
        throw POSIXError(.ENOTSUP)
    }

    func createLink(
        to item: FSItem, named name: FSFileName, inDirectory directory: FSItem
    ) async throws -> FSFileName {
        try requireWritableMount()
        throw POSIXError(.ENOTSUP)
    }

    func removeItem(
        _ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem
    ) async throws {
        try requireWritableMount()
        throw POSIXError(.ENOTSUP)
    }

    func renameItem(
        _ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
        to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?
    ) async throws -> FSFileName {
        try requireWritableMount()
        throw POSIXError(.ENOTSUP)
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
        guard let driver, let eItem = item as? XfsItem else {
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
        try requireWritableMount()
        let t0 = monotonicNanos()
        do {
            let n = try writeBytes(data, to: item, at: offset)
            stats.recordWrite(bytes: n, latencyNs: monotonicNanos() &- t0, error: false)
            return n
        } catch {
            stats.recordWrite(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
            throw error
        }
    }

    /// The body of `write`. fs_xfs_write_file rewrites bytes the file
    /// already holds, the whole range or none of it; writing past the end
    /// needs allocation and the driver refuses it with ENOTSUP, which is
    /// what FSKit is told.
    private func writeBytes(_ data: Data, to item: FSItem, at offset: off_t) throws -> Int {
        guard let driver = driver as? XfsMountedVolumeDriver,
              let eItem = item as? XfsItem else {
            throw POSIXError(.EBADF)
        }
        guard offset >= 0 else { throw POSIXError(.EINVAL) }
        // Nothing to write, and no base address to hand the C call.
        if data.isEmpty { return 0 }
        let n = data.withUnsafeBytes {
            driver.write(eItem.volumePath, at: UInt64(offset), from: $0)
        }
        guard n >= 0 else { throw driver.lastPOSIXError() }
        return Int(n)
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

    static func attributes(from attr: ReadOnlyFileAttributes,
                           parentInode: UInt64?) -> FSItem.Attributes {
        ReadOnlyVolumeSupport.fsAttributes(from: attr, parentInode: parentInode)
    }
}
