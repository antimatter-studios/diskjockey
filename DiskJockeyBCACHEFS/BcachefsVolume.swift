/*
 * BcachefsVolume.swift — FSKit volume for bcachefs, read-write.
 *
 * Implements FSVolume.Operations, ReadWriteOperations, PathConfOperations
 * and XattrOperations over a BcachefsBackend: BcachefsDriver in the
 * extension, a stand-in or the real driver under `swift test`. This file
 * makes no C call, so it builds as DiskJockeyBCACHEFSCore (diskjockey#196).
 *
 * READ-WRITE BY DEFAULT. A mount writes whenever its device is writable and
 * the mount did not ask for `ro` (BcachefsMountPolicy); every FSKit write
 * operation the driver's C ABI has is mapped: create, mkdir, remove,
 * rename, symlink, hard link, write, truncate, mode, owner and extended
 * attributes. What the driver refuses comes back as its own errno.
 *
 * WRITES REWRITE THE FILE. The C ABI replaces a file's whole contents
 * (fs_bcachefs_write_file), so a write at an offset and a size change read
 * the file, splice, and write it back, as NTFSVolume does for the same
 * reason. O(file size) per call: correct, not fast.
 *
 * EXTENDED ATTRIBUTES. bcachefs keeps them in namespaces ("user.",
 * "trusted.", "security."); macOS names have none. A macOS name N is the
 * bcachefs name "user.N", the convention Linux tools use for attributes
 * from macOS, and only the user namespace is listed: the others hold Linux
 * security and system state that has no macOS meaning.
 *
 * TIMES. The driver reports access, modification and change times; the
 * birth time is the earliest of them. It cannot set any, so a request to
 * set a time is left unconsumed, which is FSKit's way of saying it was not
 * applied.
 *
 * MIT License — see LICENSE
 */

import FSKit
import Foundation
import os
import DiskJockeyLibrary

final class BcachefsVolume: FSVolume,
                            FSVolume.Operations,
                            FSVolume.ReadWriteOperations,
                            FSVolume.PathConfOperations,
                            FSVolume.XattrOperations {

    private var backend: BcachefsBackend?
    private var policy: BcachefsMountPolicy
    private let bsdName: String
    private let stats: IOStatsCollector
    /// Called once the driver has unmounted, to release what its
    /// callbacks read through (the extension's BlockDeviceContext).
    private var releaseDevice: (() -> Void)?
    private let items = FileIDCache<BcachefsItem>()

    init(volumeID: FSVolume.Identifier,
         volumeName: FSFileName,
         backend: BcachefsBackend,
         policy: BcachefsMountPolicy,
         bsdName: String,
         stats: IOStatsCollector,
         releaseDevice: (() -> Void)? = nil) {
        self.backend = backend
        self.policy = policy
        self.bsdName = bsdName
        self.stats = stats
        self.releaseDevice = releaseDevice
        super.init(volumeID: volumeID, volumeName: volumeName)
    }

    // MARK: - Item cache

    func item(forInode inode: UInt64, path: VolumePath,
              parentInode: UInt64?) -> BcachefsItem {
        items.getOrCreate(
            id: inode,
            validate: { $0.volumePath == path && $0.parentInode == parentInode },
            create: { BcachefsItem(inode: inode, volumePath: path, parentInode: parentInode) }
        )
    }

    /// How the driver reads a path: as UTF-8 (fs_bcachefs.h takes C strings
    /// and decodes them), so a name that is not UTF-8 is refused with
    /// EILSEQ before it reaches the driver.
    static let pathEncoding: DriverPathEncoding = .utf8

    // MARK: - Capabilities

    /// The name `statfs` reports, and the one place it is spelled.
    static let fsTypeName = "bcachefs"

    /// Whether this mount writes: the policy allows it and the driver
    /// holds a write handle.
    var allowsWrites: Bool {
        policy == .readWrite && backend?.isWritable == true
    }

    /// The gate every mutating operation passes first.
    func requireWritable() throws -> BcachefsBackend {
        guard let backend else { throw POSIXError(.EBADF) }
        guard allowsWrites else { throw POSIXError(.EROFS) }
        return backend
    }

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsPersistentObjectIDs = true
        caps.supportsSymbolicLinks = true
        caps.supportsHardLinks = true
        // bcachefs has a journal; writes here are committed in place, one
        // transaction per call, so it is not one this volume keeps active.
        caps.supportsJournal = true
        caps.supportsActiveJournal = false
        caps.supportsSparseFiles = true
        caps.supports2TBFiles = true
        // Inode numbers start at 4096 and reach past 2^31 (the root
        // directory's children are 2147483648 and up).
        caps.supports64BitObjectIDs = true
        caps.caseFormat = .sensitive
        caps.doesNotSupportSettingFilePermissions = !allowsWrites
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        Self.statFS(backend?.volumeInfo(), writable: allowsWrites)
    }

    /// `statfs` from the driver's figures. Blocks are the filesystem's
    /// block size; what a caller may allocate is the free space, or none
    /// on a read-only mount. bcachefs has no fixed inode table, so the
    /// file counts are zero, which is what the fields mean when unknown.
    static func statFS(_ info: BcachefsVolumeInfo?, writable: Bool) -> FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: fsTypeName)
        guard let info, info.blockSize > 0 else { return result }
        let block = UInt64(info.blockSize)
        result.blockSize = Int(info.blockSize)
        // Writes go to the device a bucket at a time; a larger I/O size
        // also means fewer whole-file rewrites per copied file.
        result.ioSize = Int(max(info.blockSize, info.bucketSize))
        result.totalBlocks = info.totalBytes / block
        result.freeBlocks = min(info.freeBytes, info.totalBytes) / block
        result.availableBlocks = writable ? result.freeBlocks : 0
        result.totalFiles = 0
        result.freeFiles = 0
        return result
    }

    // MARK: - Lifecycle

    func mount(options: FSTaskOptions) async throws {
        applyMountOptions(options.taskOptions)
        log.info("volume: mount (\(allowsWrites ? "read-write" : "read-only"))",
                 scope: AppLogScope.lifecycle)
    }

    /// FSKit can deliver the mount's options after load. A read-only
    /// request turns a read-write volume read-only for good; nothing turns
    /// a read-only one writable.
    func applyMountOptions(_ options: [String]) {
        if BcachefsMountPolicy.asksReadOnly(options) {
            policy = .readOnly
        }
    }

    func unmount() async {
        log.info("volume: unmount", scope: AppLogScope.lifecycle)
        shutDown()
    }

    func activate(options: FSTaskOptions) async throws -> FSItem {
        log.info("volume: activate", scope: AppLogScope.lifecycle)
        return try rootItem()
    }

    /// The body of `activate`, which a test can call: FSTaskOptions has
    /// no public initialiser.
    func rootItem() throws -> BcachefsItem {
        guard let backend else { throw POSIXError(.EIO) }
        // A root that cannot be read is a mount that failed.
        guard let root = backend.stat(.root) else { throw backend.lastError() }
        return item(forInode: root.inode, path: .root, parentInode: nil)
    }

    func deactivate(options: FSDeactivateOptions) async throws {
        log.info("volume: deactivate", scope: AppLogScope.lifecycle)
        stats.stop()
        shutDown()
    }

    /// Unmounts the driver, then releases its device. Safe to call twice.
    func shutDown() {
        backend?.unmount()
        backend = nil
        releaseDevice?()
        releaseDevice = nil
    }

    // MARK: - Attributes

    func attributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem
    ) async throws -> FSItem.Attributes {
        guard let backend, let bItem = item as? BcachefsItem else {
            throw POSIXError(.EBADF)
        }
        guard let attr = backend.stat(bItem.volumePath) else {
            throw backend.lastError()
        }
        return Self.attributes(from: attr, parentInode: bItem.parentInode)
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem
    ) async throws -> FSItem.Attributes {
        let backend = try requireWritable()
        guard let bItem = item as? BcachefsItem else { throw POSIXError(.EBADF) }
        let path = bItem.volumePath
        var consumed: FSItem.Attribute = []

        if newAttributes.isValid(.size) {
            try truncate(path, to: newAttributes.size, backend: backend)
            consumed.insert(.size)
        }
        if newAttributes.isValid(.mode) {
            let rc = backend.chmod(path, mode: newAttributes.mode & 0o7777)
            guard rc == 0 else { throw backend.error(returned: rc) }
            consumed.insert(.mode)
        }
        if newAttributes.isValid(.uid) || newAttributes.isValid(.gid) {
            // fs_bcachefs_chown sets both; the one not asked for keeps
            // its value.
            guard let attr = backend.stat(path) else { throw backend.lastError() }
            let uid = newAttributes.isValid(.uid) ? newAttributes.uid : attr.uid
            let gid = newAttributes.isValid(.gid) ? newAttributes.gid : attr.gid
            let rc = backend.chown(path, uid: uid, gid: gid)
            guard rc == 0 else { throw backend.error(returned: rc) }
            if newAttributes.isValid(.uid) { consumed.insert(.uid) }
            if newAttributes.isValid(.gid) { consumed.insert(.gid) }
        }
        // Times and flags: the C ABI cannot set them, so they stay
        // unconsumed (see the header).
        newAttributes.consumedAttributes = consumed

        guard let attr = backend.stat(path) else { throw backend.lastError() }
        return Self.attributes(from: attr, parentInode: bItem.parentInode)
    }

    /// Sets `path`'s size: the bytes up to `size` kept, zeros past the old
    /// end, written back whole.
    private func truncate(_ path: VolumePath, to size: UInt64,
                          backend: BcachefsBackend) throws {
        guard let attr = backend.stat(path) else { throw backend.lastError() }
        guard attr.fileType == .file else {
            throw POSIXError(attr.fileType == .directory ? .EISDIR : .EINVAL)
        }
        if attr.size == size { return }
        guard let count = Int(exactly: size) else { throw POSIXError(.EFBIG) }
        var bytes = [UInt8](repeating: 0, count: count)
        let keep = Int(min(attr.size, size))
        if keep > 0 {
            let n = bytes.withUnsafeMutableBytes { buf in
                backend.read(path, at: 0, into: UnsafeMutableRawBufferPointer(rebasing: buf.prefix(keep)))
            }
            guard n >= 0 else { throw backend.lastError() }
            guard n == Int64(keep) else { throw POSIXError(.EIO) }
        }
        let rc = bytes.withUnsafeBytes { backend.writeFile(path, $0) }
        guard rc == 0 else { throw backend.error(returned: rc) }
    }

    // MARK: - Lookup / enumeration

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> (FSItem, FSFileName) {
        guard let backend, let dirItem = directory as? BcachefsItem else {
            throw POSIXError(.EBADF)
        }
        let childPath = try dirItem.volumePath.child(name, for: Self.pathEncoding)
        guard let attr = backend.stat(childPath) else { throw backend.lastError() }
        return (item(forInode: attr.inode, path: childPath, parentInode: dirItem.inode), name)
    }

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker
    ) async throws -> FSDirectoryVerifier {
        guard let dirItem = directory as? BcachefsItem else {
            throw POSIXError(.EBADF)
        }
        let end = try entries(of: dirItem, after: cookie.rawValue,
                              withAttributes: attributes != nil) { $0.pack(into: packer) }
        return FSDirectoryVerifier(rawValue: end)
    }

    /// The body of `enumerateDirectory`, with the packer as a closure so a
    /// test can stand in for it. Answers the cookie after the last entry
    /// packed. The driver lists no "." or "..": FSKit supplies those.
    func entries(
        of dirItem: BcachefsItem,
        after startCookie: UInt64,
        withAttributes: Bool,
        pack: (PackableDirectoryEntry) -> Bool
    ) throws -> UInt64 {
        guard let backend else { throw POSIXError(.EBADF) }

        var entryCookie: UInt64 = 1
        let walk = backend.walkDirectory(dirItem.volumePath) { entry in
            if entryCookie <= startCookie {
                entryCookie += 1
                return true
            }
            // Nil for a name the driver cannot be handed (not UTF-8): the
            // entry is still listed, under its real bytes, without
            // attributes.
            let childPath = try? dirItem.volumePath.child(entry.name, for: Self.pathEncoding)
            var itemAttrs: FSItem.Attributes? = nil
            if withAttributes, let childPath, let attr = backend.stat(childPath) {
                itemAttrs = Self.attributes(from: attr, parentInode: dirItem.inode)
            }
            let packed = pack(PackableDirectoryEntry(
                name: DirentName.fileName(entry.name),
                itemType: entry.fileType.fsItemType,
                itemID: FSItem.Identifier(rawValue: Self.listedID(entry)) ?? .invalid,
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
            throw POSIXError(.EIO)
        }
    }

    /// The identifier an entry is listed under. A subvolume's dirent carries
    /// the subvolume's id (1, 2, 3, ...), not an inode number, and those
    /// small numbers are FSKit's own (2 is the root directory), so it is
    /// listed from the top of the range down, where no bcachefs inode is.
    static func listedID(_ entry: BcachefsDirectoryEntry) -> UInt64 {
        entry.fileType == .subvolume ? UInt64.max - entry.inode : entry.inode
    }

    func reclaimItem(_ item: FSItem) async throws {
        if let bItem = item as? BcachefsItem {
            items.remove(id: bItem.inode)
        }
    }

    // MARK: - Symlinks

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        guard let backend, let bItem = item as? BcachefsItem else {
            throw POSIXError(.EBADF)
        }
        guard let target = backend.readlink(bItem.volumePath) else {
            throw backend.lastError()
        }
        // A target is a path, and a path is bytes (diskjockey#219).
        return FSFileName(data: Data(target))
    }

    // MARK: - Mutating operations

    func createItem(
        named name: FSFileName, type: FSItem.ItemType,
        inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest
    ) async throws -> (FSItem, FSFileName) {
        let backend = try requireWritable()
        guard let dirItem = directory as? BcachefsItem else { throw POSIXError(.EBADF) }
        let childPath = try dirItem.volumePath.child(name, for: Self.pathEncoding)
        let defaultMode: UInt32 = type == .directory ? 0o755 : 0o644
        let mode = attributes.isValid(.mode) ? attributes.mode & 0o7777 : defaultMode

        let rc: Int32
        switch type {
        case .file: rc = backend.create(childPath, mode: mode)
        case .directory: rc = backend.mkdir(childPath, mode: mode)
        // Symlinks have their own entry point; devices, fifos and sockets
        // have no call in the C ABI.
        case .symlink: throw POSIXError(.EINVAL)
        default: throw POSIXError(.ENOTSUP)
        }
        guard rc == 0 else { throw backend.error(returned: rc) }

        var consumed: FSItem.Attribute = []
        if attributes.isValid(.mode) { consumed.insert(.mode) }
        // An owner asked for at create is set right after it; a refusal
        // leaves it unconsumed rather than failing a create that happened.
        if attributes.isValid(.uid) || attributes.isValid(.gid),
           let made = backend.stat(childPath) {
            let uid = attributes.isValid(.uid) ? attributes.uid : made.uid
            let gid = attributes.isValid(.gid) ? attributes.gid : made.gid
            if (uid, gid) == (made.uid, made.gid) || backend.chown(childPath, uid: uid, gid: gid) == 0 {
                if attributes.isValid(.uid) { consumed.insert(.uid) }
                if attributes.isValid(.gid) { consumed.insert(.gid) }
            }
        }
        attributes.consumedAttributes = consumed

        guard let attr = backend.stat(childPath) else { throw backend.lastError() }
        return (item(forInode: attr.inode, path: childPath, parentInode: dirItem.inode), name)
    }

    func createSymbolicLink(
        named name: FSFileName, inDirectory directory: FSItem,
        attributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName
    ) async throws -> (FSItem, FSFileName) {
        let backend = try requireWritable()
        guard let dirItem = directory as? BcachefsItem else { throw POSIXError(.EBADF) }
        // The target crosses the ABI as a C string: an empty one, or one
        // holding a NUL, cannot be stored.
        let target = [UInt8](contents.data)
        guard !target.isEmpty, !target.contains(0) else { throw POSIXError(.EINVAL) }
        let childPath = try dirItem.volumePath.child(name, for: Self.pathEncoding)
        let rc = backend.symlink(childPath, target: target)
        guard rc == 0 else { throw backend.error(returned: rc) }
        guard let attr = backend.stat(childPath) else { throw backend.lastError() }
        return (item(forInode: attr.inode, path: childPath, parentInode: dirItem.inode), name)
    }

    func createLink(
        to item: FSItem, named name: FSFileName, inDirectory directory: FSItem
    ) async throws -> FSFileName {
        let backend = try requireWritable()
        guard let dirItem = directory as? BcachefsItem,
              let bItem = item as? BcachefsItem else { throw POSIXError(.EBADF) }
        let linkPath = try dirItem.volumePath.child(name, for: Self.pathEncoding)
        let rc = backend.link(bItem.volumePath, to: linkPath)
        guard rc == 0 else { throw backend.error(returned: rc) }
        return name
    }

    func removeItem(
        _ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem
    ) async throws {
        let backend = try requireWritable()
        guard let dirItem = directory as? BcachefsItem else { throw POSIXError(.EBADF) }
        let childPath = try dirItem.volumePath.child(name, for: Self.pathEncoding)
        guard let attr = backend.stat(childPath) else { throw backend.lastError() }
        let rc = attr.fileType == .directory ? backend.rmdir(childPath) : backend.unlink(childPath)
        guard rc == 0 else { throw backend.error(returned: rc) }
    }

    func renameItem(
        _ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
        to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?
    ) async throws -> FSFileName {
        let backend = try requireWritable()
        guard let srcDir = sourceDirectory as? BcachefsItem,
              let dstDir = destinationDirectory as? BcachefsItem else { throw POSIXError(.EBADF) }
        let from = try srcDir.volumePath.child(sourceName, for: Self.pathEncoding)
        let to = try dstDir.volumePath.child(destinationName, for: Self.pathEncoding)
        // The driver replaces a file at `to` itself; nothing is unlinked
        // here first, so a refused rename loses nothing.
        let rc = backend.rename(from, to: to)
        guard rc == 0 else { throw backend.error(returned: rc) }
        if let moved = item as? BcachefsItem {
            items.moved(moved, to: to, parentID: dstDir.id)
        }
        return destinationName
    }

    func synchronize(flags: FSSyncFlags) async throws {
        // Every write is committed to the device before it returns.
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

    /// The body of `read`, over a plain buffer so a test can supply one.
    func readBytes(
        from item: FSItem, at offset: off_t,
        into buffer: UnsafeMutableRawBufferPointer
    ) throws -> Int {
        guard let backend, let bItem = item as? BcachefsItem else {
            throw POSIXError(.EBADF)
        }
        guard offset >= 0 else { throw POSIXError(.EINVAL) }
        if buffer.isEmpty { return 0 }
        let n = backend.read(bItem.volumePath, at: UInt64(offset), into: buffer)
        // Negative is a failure, never the end of the file.
        guard n >= 0 else { throw backend.lastError() }
        return Int(n)
    }

    func write(
        contents data: Data, to item: FSItem, at offset: off_t
    ) async throws -> Int {
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

    /// The body of `write`: the file read whole, `data` spliced in at
    /// `offset` (zeros fill a gap past the old end), and written back.
    func writeBytes(_ data: Data, to item: FSItem, at offset: off_t) throws -> Int {
        let backend = try requireWritable()
        guard let bItem = item as? BcachefsItem else { throw POSIXError(.EBADF) }
        guard offset >= 0 else { throw POSIXError(.EINVAL) }
        // POSIX write(2): zero bytes have no other result.
        if data.isEmpty { return 0 }
        let path = bItem.volumePath
        guard let attr = backend.stat(path) else { throw backend.lastError() }
        guard attr.fileType == .file else {
            throw POSIXError(attr.fileType == .directory ? .EISDIR : .EINVAL)
        }
        let start = UInt64(offset)
        let (end, overflow) = start.addingReportingOverflow(UInt64(data.count))
        guard !overflow, let total = Int(exactly: max(attr.size, end)) else {
            throw POSIXError(.EFBIG)
        }

        // From the start, covering the whole file: nothing to keep.
        if start == 0 && end >= attr.size {
            let rc = data.withUnsafeBytes { backend.writeFile(path, $0) }
            guard rc == 0 else { throw backend.error(returned: rc) }
            return data.count
        }

        var bytes = [UInt8](repeating: 0, count: total)
        let keep = Int(attr.size)
        if keep > 0 {
            let n = bytes.withUnsafeMutableBytes { buf in
                backend.read(path, at: 0, into: UnsafeMutableRawBufferPointer(rebasing: buf.prefix(keep)))
            }
            guard n >= 0 else { throw backend.lastError() }
            guard n == Int64(keep) else { throw POSIXError(.EIO) }
        }
        bytes.replaceSubrange(Int(start)..<Int(end), with: data)
        let rc = bytes.withUnsafeBytes { backend.writeFile(path, $0) }
        guard rc == 0 else { throw backend.error(returned: rc) }
        return data.count
    }

    // MARK: - XattrOperations

    /// The bcachefs name for a macOS attribute name: in the user namespace.
    static func driverXattrName(_ name: FSFileName) throws -> [UInt8] {
        let bytes = [UInt8](name.data)
        guard !bytes.isEmpty, !bytes.contains(0) else { throw POSIXError(.EINVAL) }
        return Array("user.".utf8) + bytes
    }

    /// The macOS name for a bcachefs one: the user namespace's names
    /// without the prefix; nil for every other namespace.
    static func macXattrName(_ driverName: [UInt8]) -> [UInt8]? {
        let prefix = Array("user.".utf8)
        guard driverName.count > prefix.count, driverName.starts(with: prefix) else { return nil }
        return Array(driverName.dropFirst(prefix.count))
    }

    func xattr(named name: FSFileName, of item: FSItem) async throws -> Data {
        guard let backend, let bItem = item as? BcachefsItem else {
            throw POSIXError(.EBADF)
        }
        let driverName = try Self.driverXattrName(name)
        guard let value = backend.getXattr(bItem.volumePath, name: driverName) else {
            throw backend.lastError()
        }
        return Data(value)
    }

    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem,
                  policy: FSVolume.SetXattrPolicy) async throws {
        let backend = try requireWritable()
        guard let bItem = item as? BcachefsItem else { throw POSIXError(.EBADF) }
        let path = bItem.volumePath
        let driverName = try Self.driverXattrName(name)
        // MustCreate, MustReplace and Delete each depend on whether the
        // attribute is there now; ENOATTR from the driver says it is not.
        func exists() throws -> Bool {
            if backend.getXattr(path, name: driverName) != nil { return true }
            let errno = backend.lastErrno()
            if errno == ENOATTR { return false }
            throw Self.error(errno)
        }
        switch policy {
        case .delete:
            guard try exists() else { throw POSIXError(.ENOATTR) }
            let rc = backend.removeXattr(path, name: driverName)
            guard rc == 0 else { throw backend.error(returned: rc) }
            return
        case .mustCreate:
            if try exists() { throw POSIXError(.EEXIST) }
        case .mustReplace:
            guard try exists() else { throw POSIXError(.ENOATTR) }
        case .alwaysSet:
            break
        @unknown default:
            throw POSIXError(.EINVAL)
        }
        guard let value else { throw POSIXError(.EINVAL) }
        let rc = backend.setXattr(path, name: driverName, value: [UInt8](value))
        guard rc == 0 else { throw backend.error(returned: rc) }
    }

    func xattrs(of item: FSItem) async throws -> [FSFileName] {
        guard let backend, let bItem = item as? BcachefsItem else {
            throw POSIXError(.EBADF)
        }
        guard let names = backend.listXattrs(bItem.volumePath) else {
            throw backend.lastError()
        }
        return names.compactMap(Self.macXattrName).map { FSFileName(data: Data($0)) }
    }

    private static func error(_ errno: Int32) -> POSIXError {
        guard errno > 0, let code = POSIXErrorCode(rawValue: errno) else {
            return POSIXError(.EIO)
        }
        return POSIXError(code)
    }

    // MARK: - PathConfOperations

    var maximumLinkCount: Int { -1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    /// The driver refuses a value over 65535 bytes.
    var maximumXattrSize: Int { 65_535 }
    var maximumFileSize: UInt64 { UInt64(Int64.max) }

    // MARK: - Helpers

    /// FSKit's attributes for a driver's, covering FSKit's whole standard
    /// set: an incomplete one makes the connector reject the reply.
    static func attributes(from attr: BcachefsFileAttributes,
                           parentInode: UInt64?) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.type = attr.fileType.fsItemType
        attrs.mode = attr.mode & 0o7777
        attrs.uid = attr.uid
        attrs.gid = attr.gid
        attrs.flags = 0
        attrs.size = attr.size
        attrs.allocSize = attr.sectors.multipliedReportingOverflow(by: 512).overflow
            ? UInt64.max : attr.sectors * 512
        attrs.linkCount = attr.linkCount
        attrs.accessTime = attr.accessTime.timespec
        attrs.modifyTime = attr.modifyTime.timespec
        attrs.changeTime = attr.changeTime.timespec
        attrs.birthTime = earliest(attr.accessTime, attr.modifyTime, attr.changeTime).timespec
        if let id = FSItem.Identifier(rawValue: attr.inode) {
            attrs.fileID = id
        }
        // Root's parent is FSKit's parent-of-root sentinel.
        attrs.parentID = parentInode.flatMap { FSItem.Identifier(rawValue: $0) } ?? .parentOfRoot
        return attrs
    }

    static func earliest(_ times: BcachefsTime...) -> BcachefsTime {
        times.min { ($0.seconds, $0.nanoseconds) < ($1.seconds, $1.nanoseconds) } ?? .epoch
    }
}
