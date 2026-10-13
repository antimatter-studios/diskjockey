/*
 * XfsVolume.swift — FSKit volume for XFS.
 *
 * Implements FSVolume.Operations + FSVolume.ReadWriteOperations +
 * FSVolume.PathConfOperations + FSVolume.XattrOperations. Mutating
 * operations require a writable mount: writable hardware, a mounted driver
 * that can write, and no ro or --rdonly (diskjockey#343); read-only mounts
 * return EROFS. Writes, size, mode, owner and time changes, creates,
 * removals, renames, hard links and extended attributes each reach the
 * driver's logged record (diskjockey#322, #326, #327, #328); what the
 * driver cannot make (a symlink, a device) returns ENOTSUP.
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
                         FSVolume.PathConfOperations,
                         FSVolume.XattrOperations {

    private var driver: ReadOnlyVolumeDriver?
    private var mountAccess: XfsMountAccess
    private var contextPtr: UnsafeMutableRawPointer?
    private let bsdName: String
    private let stats: IOStatsCollector
    private let items = FileIDCache<XfsItem>()

    /// The lock a check task holds while it reads the volume (#324), the
    /// same instance the extension's `MountedResource` holds. Every
    /// operation here asks it first: while a verify holds it, the volume
    /// answers EBUSY rather than change, or read, what is being checked.
    private let opLock: OperationLock

    init(volumeID: FSVolume.Identifier,
         volumeName: FSFileName,
         driver: ReadOnlyVolumeDriver,
         contextPtr: UnsafeMutableRawPointer?,
         bsdName: String,
         stats: IOStatsCollector,
         mountAccess: XfsMountAccess = .readOnly,
         opLock: OperationLock = OperationLock()) {
        self.driver = driver
        self.mountAccess = mountAccess
        self.contextPtr = contextPtr
        self.bsdName = bsdName
        self.stats = stats
        self.opLock = opLock
        super.init(volumeID: volumeID, volumeName: volumeName)
    }

    /// EBUSY while a check that quiesces the volume holds the lock. The
    /// quick check the system runs while mounting does not quiesce it:
    /// the operations that arrive during it are the mount's own, and
    /// refusing them fails the mount (diskjockey#166).
    func ensureIdle() throws {
        if let current = opLock.current, current.quiescesVolume {
            log.info("EBUSY: refusing op — \(current.displayName) in progress", scope: AppLogScope.io)
            throw POSIXError(.EBUSY)
        }
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

    /// FSKit keeps a file unlinked while open alive for its open handles
    /// (diskjockey#354): rust-fs-xfs frees an inode with its last name, so
    /// without this a handle on an unlinked file reads nothing. FSKit reads
    /// it once, after the resource loads, whatever the mount's access.
    @available(macOS 26.0, *)
    var enableOpenUnlinkEmulation: Bool {
        get { true }
        set {}
    }

    var allowsWrites: Bool {
        mountAccess.allowsWrites && (driver as? XfsMountedVolumeDriver)?.isWritable == true
    }

    /// Mutating operation adapters use this same gate. Their implementation
    /// is separate from mount authorization; unsupported operations stay so.
    func requireWritableMount() throws {
        guard allowsWrites else { throw POSIXError(.EROFS) }
    }

    /// The mounted driver, when this mount may write through it; EROFS
    /// when it may not.
    private func writableDriver() throws -> XfsMountedVolumeDriver {
        try requireWritableMount()
        guard let driver = driver as? XfsMountedVolumeDriver else { throw POSIXError(.EROFS) }
        return driver
    }

    var volumeStatistics: FSStatFSResult {
        guard let info = driver?.volumeInfo() else {
            return FSStatFSResult(fileSystemTypeName: Self.fsTypeName)
        }
        let result = ReadOnlyVolumeSupport.statFS(info, fileSystemTypeName: Self.fsTypeName)
        // What Finder checks before it copies: a writable mount offers the
        // blocks that are free, a read-only one none of them.
        if allowsWrites {
            result.availableBlocks = result.freeBlocks
        }
        return result
    }

    // MARK: - Lifecycle

    func mount(options: FSTaskOptions) async throws {
        try applyMountOptions(options.taskOptions)
        log.info("volume: mount", scope: AppLogScope.lifecycle)
    }

    /// FSKit can deliver mount options after load. They can revoke writes
    /// (`ro`, `--rdonly`) but never grant them: a loaded read-only handle
    /// stays read-only, and asking for `rw` then is not an error, because
    /// read-write is only ever the default (diskjockey#343).
    func applyMountOptions(_ options: [String]) throws {
        if XfsMountPolicy(options: options) == .readOnly {
            mountAccess = .readOnly
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
        try ensureIdle()
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

    /// Size through fs_xfs_truncate, which stamps the modification time in
    /// the same record; mode, owner and the access and modification times
    /// through one fs_xfs_set_attributes (diskjockey#328). A field the ABI
    /// cannot set refuses the whole request before anything is written.
    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem
    ) async throws -> FSItem.Attributes {
        try ensureIdle()
        let driver = try writableDriver()
        guard let eItem = item as? XfsItem else { throw POSIXError(.EBADF) }
        let unsettable: [FSItem.Attribute] = [
            .type, .linkCount, .flags, .allocSize, .fileID, .parentID,
            .changeTime, .birthTime, .backupTime, .addedTime,
        ]
        guard !unsettable.contains(where: { newAttributes.isValid($0) }) else {
            throw POSIXError(.ENOTSUP)
        }

        var consumed: FSItem.Attribute = []
        defer { newAttributes.consumedAttributes = consumed }
        var modified: timespec? = newAttributes.isValid(.modifyTime) ? newAttributes.modifyTime : nil
        if newAttributes.isValid(.size) {
            // A size change moves mtime; a requested time rides along.
            guard driver.truncate(eItem.volumePath, to: newAttributes.size,
                                  modified: modified ?? Self.now()) == 0 else {
                throw driver.lastPOSIXError()
            }
            consumed.insert(.size)
            if modified != nil { consumed.insert(.modifyTime) }
            modified = nil
        }
        // chmod changes permission bits; the type bits are not an attribute.
        let mode = newAttributes.isValid(.mode) ? newAttributes.mode & 0o7777 : nil
        let uid = newAttributes.isValid(.uid) ? newAttributes.uid : nil
        let gid = newAttributes.isValid(.gid) ? newAttributes.gid : nil
        let accessed = newAttributes.isValid(.accessTime) ? newAttributes.accessTime : nil
        if mode != nil || uid != nil || gid != nil || accessed != nil || modified != nil {
            guard driver.setAttributes(eItem.volumePath, mode: mode, uid: uid, gid: gid,
                                       accessed: accessed, modified: modified) == 0 else {
                throw driver.lastPOSIXError()
            }
            if mode != nil { consumed.insert(.mode) }
            if uid != nil { consumed.insert(.uid) }
            if gid != nil { consumed.insert(.gid) }
            if accessed != nil { consumed.insert(.accessTime) }
            if modified != nil { consumed.insert(.modifyTime) }
        }
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
        try ensureIdle()
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
        try ensureIdle()
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
        try ensureIdle()
        if let eItem = item as? XfsItem {
            items.remove(id: eItem.inode)
        }
    }

    // MARK: - Symlink

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        try ensureIdle()
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

    // MARK: - Mutating ops (mount gate, then the driver's logged record)

    /// fs_xfs_create or fs_xfs_mkdir (diskjockey#326). The C ABI makes
    /// regular files and directories; a device, fifo or socket has no call
    /// to make it, and a symlink has its own entry point.
    func createItem(
        named name: FSFileName, type: FSItem.ItemType,
        inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest
    ) async throws -> (FSItem, FSFileName) {
        try ensureIdle()
        let driver = try writableDriver()
        guard let dirItem = directory as? XfsItem else { throw POSIXError(.EBADF) }
        let isDirectory: Bool
        switch type {
        case .file: isDirectory = false
        case .directory: isDirectory = true
        default: throw POSIXError(.ENOTSUP)
        }
        let childPath = try dirItem.volumePath.child(name, for: Self.pathEncoding)
        let requested = attributes.isValid(.mode) ? attributes.mode & 0o7777 : nil
        let mode = UInt16(requested ?? (isDirectory ? 0o755 : 0o644))
        let inode = isDirectory ? driver.mkdir(childPath, mode: mode)
                                : driver.create(childPath, mode: mode)
        guard inode != 0 else { throw driver.lastPOSIXError() }

        var consumed: FSItem.Attribute = []
        if requested != nil { consumed.insert(.mode) }
        // The new inode belongs to uid 0 and gid 0 (fs_xfs.h). An owner asked
        // for is set right after, and a refusal leaves it unconsumed rather
        // than failing a create that happened.
        if attributes.isValid(.uid) || attributes.isValid(.gid) {
            let uid = attributes.isValid(.uid) ? attributes.uid : nil
            let gid = attributes.isValid(.gid) ? attributes.gid : nil
            if driver.setAttributes(childPath, mode: nil, uid: uid, gid: gid,
                                    accessed: nil, modified: nil) == 0 {
                if uid != nil { consumed.insert(.uid) }
                if gid != nil { consumed.insert(.gid) }
            }
        }
        attributes.consumedAttributes = consumed
        return (item(forInode: inode, path: childPath, parentInode: dirItem.inode), name)
    }

    /// rust-fs-xfs makes no symlink: its features page lists "Create a
    /// symlink" as not supported, and the C ABI has no call for one. Nothing
    /// is written (diskjockey#327).
    func createSymbolicLink(
        named name: FSFileName, inDirectory directory: FSItem,
        attributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName
    ) async throws -> (FSItem, FSFileName) {
        try ensureIdle()
        _ = try writableDriver()
        throw POSIXError(.ENOTSUP)
    }

    /// fs_xfs_link (diskjockey#327). A directory is the driver's EPERM.
    func createLink(
        to item: FSItem, named name: FSFileName, inDirectory directory: FSItem
    ) async throws -> FSFileName {
        try ensureIdle()
        let driver = try writableDriver()
        guard let dirItem = directory as? XfsItem,
              let target = item as? XfsItem else { throw POSIXError(.EBADF) }
        let linkPath = try dirItem.volumePath.child(name, for: Self.pathEncoding)
        guard driver.link(target.volumePath, to: linkPath) == 0 else {
            throw driver.lastPOSIXError()
        }
        return name
    }

    /// fs_xfs_unlink, or fs_xfs_rmdir for a directory (diskjockey#326),
    /// chosen by what the name is now rather than what the item was.
    func removeItem(
        _ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem
    ) async throws {
        try ensureIdle()
        let driver = try writableDriver()
        guard let dirItem = directory as? XfsItem else { throw POSIXError(.EBADF) }
        let childPath = try dirItem.volumePath.child(name, for: Self.pathEncoding)
        guard let attr = driver.stat(childPath) else { throw driver.lastPOSIXError() }
        let rc = attr.fileType == .directory ? driver.rmdir(childPath) : driver.unlink(childPath)
        guard rc == 0 else { throw driver.lastPOSIXError() }
    }

    /// fs_xfs_rename2 with FS_XFS_RENAME_REPLACE (diskjockey#327): a name
    /// at the destination is replaced as rename(2) replaces it, in the
    /// same record. FSKit passes `overItem` only when the kernel had
    /// already resolved the destination, so the replace is always asked
    /// for, and nothing is unlinked here first: a refused rename loses
    /// nothing.
    func renameItem(
        _ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
        to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?
    ) async throws -> FSFileName {
        try ensureIdle()
        let driver = try writableDriver()
        guard let srcDir = sourceDirectory as? XfsItem,
              let dstDir = destinationDirectory as? XfsItem else { throw POSIXError(.EBADF) }
        let from = try srcDir.volumePath.child(sourceName, for: Self.pathEncoding)
        let to = try dstDir.volumePath.child(destinationName, for: Self.pathEncoding)
        guard driver.rename(from, to: to, replace: true) == 0 else {
            throw driver.lastPOSIXError()
        }
        if let moved = item as? XfsItem {
            items.moved(moved, to: to, parentID: dstDir.inode)
        }
        return destinationName
    }

    /// FSKit's fsync for the volume: what the handle has logged goes home,
    /// and a failure is the driver's errno. A read-only mount has nothing
    /// to flush.
    func synchronize(flags: FSSyncFlags) async throws {
        try ensureIdle()
        guard allowsWrites, let driver = driver as? XfsMountedVolumeDriver else { return }
        if driver.flush() != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: driver.lastErrno()) ?? .EIO)
        }
    }

    // MARK: - ReadWriteOperations

    func read(
        from item: FSItem, at offset: off_t, length: Int,
        into buffer: FSMutableFileDataBuffer
    ) async throws -> Int {
        try ensureIdle()
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
        try ensureIdle()
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

    // MARK: - XattrOperations

    /// fs_xfs_setxattr's flags (FS_XFS_XATTR_CREATE, FS_XFS_XATTR_REPLACE).
    static let xattrMustCreate: Int32 = 1
    static let xattrMustReplace: Int32 = 2

    /// macOS hands an ACL over as this attribute, an NFSv4-style ACL.
    /// Stored as a POSIX ACL or as plain bytes it would change meaning.
    static let macACLName = Array("com.apple.system.Security".utf8)

    /// The XFS name for a macOS attribute name: in the user namespace.
    static func driverXattrName(_ name: FSFileName) throws -> [UInt8] {
        let bytes = [UInt8](name.data)
        guard !bytes.isEmpty, !bytes.contains(0) else { throw POSIXError(.EINVAL) }
        return Array("user.".utf8) + bytes
    }

    /// The macOS name for an XFS one: the user namespace's names without
    /// the prefix; nil for the trusted, security and system namespaces,
    /// which are not a macOS caller's.
    static func macXattrName(_ driverName: [UInt8]) -> [UInt8]? {
        let prefix = Array("user.".utf8)
        guard driverName.count > prefix.count, driverName.starts(with: prefix) else { return nil }
        return Array(driverName.dropFirst(prefix.count))
    }

    func xattr(named name: FSFileName, of item: FSItem) async throws -> Data {
        try ensureIdle()
        guard let driver = driver as? XfsMountedVolumeDriver,
              let eItem = item as? XfsItem else { throw POSIXError(.EBADF) }
        guard let value = driver.getXattr(eItem.volumePath, name: try Self.driverXattrName(name)) else {
            throw driver.lastPOSIXError()
        }
        return Data(value)
    }

    /// FSKit's set policies are the driver's own flags, so whether the
    /// attribute is there is decided in the same record that writes it.
    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem,
                  policy: FSVolume.SetXattrPolicy) async throws {
        try ensureIdle()
        let driver = try writableDriver()
        guard let eItem = item as? XfsItem else { throw POSIXError(.EBADF) }
        guard [UInt8](name.data) != Self.macACLName else { throw POSIXError(.ENOTSUP) }
        let driverName = try Self.driverXattrName(name)
        let rc: Int32
        switch policy {
        case .delete:
            rc = driver.removeXattr(eItem.volumePath, name: driverName)
        case .alwaysSet, .mustCreate, .mustReplace:
            guard let value else { throw POSIXError(.EINVAL) }
            let flags = policy == .mustCreate ? Self.xattrMustCreate
                : policy == .mustReplace ? Self.xattrMustReplace : 0
            rc = driver.setXattr(eItem.volumePath, name: driverName, value: [UInt8](value),
                                 flags: flags)
        @unknown default:
            throw POSIXError(.EINVAL)
        }
        guard rc == 0 else { throw driver.lastPOSIXError() }
    }

    func xattrs(of item: FSItem) async throws -> [FSFileName] {
        try ensureIdle()
        guard let driver = driver as? XfsMountedVolumeDriver,
              let eItem = item as? XfsItem else { throw POSIXError(.EBADF) }
        guard let names = driver.listXattrs(eItem.volumePath) else {
            throw driver.lastPOSIXError()
        }
        return names.compactMap(Self.macXattrName).map { FSFileName(data: Data($0)) }
    }

    // MARK: - PathConfOperations

    var maximumLinkCount: Int { -1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    /// The driver stores a value of up to 65536 bytes.
    var maximumXattrSize: Int { 65_536 }

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
