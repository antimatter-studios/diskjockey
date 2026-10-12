//
//  BcachefsVolumeTests.swift — the REAL BcachefsVolume, over a backend that
//  keeps a tree in memory and records what it is asked.
//
//  These pin the volume's own decisions: what each FSKit operation asks of
//  the driver, how a failure's errno reaches FSKit, when a mount writes,
//  how extended attribute names cross between macOS and bcachefs, and what
//  statfs reports. Expected values come from FSKit's contract, from POSIX
//  and from fs_bcachefs.h — never from the body under test. What the real
//  driver does with the same calls, on images the reference tools made, is
//  BcachefsImageTests.swift.
//
//  Host-free: no app, no extension bundle, nothing launched.
//

import Foundation
import FSKit
import Testing
@testable import DiskJockeyBCACHEFSCore
@testable import DiskJockeyLibrary

// MARK: - A backend that keeps a tree

private final class TreeBackend: BcachefsBackend {

    struct Node {
        var attr: BcachefsFileAttributes
        var data: [UInt8] = []
        var target: [UInt8]? = nil
        var xattrs: [[UInt8]: [UInt8]] = [:]
    }

    enum Call: Equatable {
        case create(String, mode: UInt32)
        case mkdir(String, mode: UInt32)
        case unlink(String)
        case rmdir(String)
        case rename(String, String)
        case symlink(String, target: [UInt8])
        case link(String, String)
        case writeFile(String, [UInt8])
        case chmod(String, mode: UInt32)
        case chown(String, uid: UInt32, gid: UInt32)
        case setXattr(String, name: [UInt8], value: [UInt8])
        case removeXattr(String, name: [UInt8])
    }

    var nodes: [VolumePath: Node] = [:]
    var errno: Int32 = 0
    var isWritable = true
    var info: BcachefsVolumeInfo?
    /// Writes that fail with this negative errno instead of happening.
    var writeFailure: Int32?
    /// Paths whose stat fails with this errno.
    var statFailures: [VolumePath: Int32] = [:]
    private(set) var calls: [Call] = []
    private(set) var unmounts = 0
    private var nextInode: UInt64 = 0x8000_0000

    init() {
        nodes[.root] = Node(attr: Self.attr(inode: 4096, mode: 0o040755))
    }

    static func attr(inode: UInt64, mode: UInt32, size: UInt64 = 0,
                     links: UInt32 = 1) -> BcachefsFileAttributes {
        BcachefsFileAttributes(inode: inode, mode: mode, linkCount: links, uid: 0, gid: 0,
                               size: size, sectors: (size + 511) / 512)
    }

    func add(_ path: VolumePath, mode: UInt32, data: [UInt8] = [], target: [UInt8]? = nil) {
        nextInode += 1
        nodes[path] = Node(attr: Self.attr(inode: nextInode, mode: mode,
                                           size: UInt64(target?.count ?? data.count)),
                           data: data, target: target)
    }

    func volumeInfo() -> BcachefsVolumeInfo? { info }

    func stat(_ path: VolumePath) -> BcachefsFileAttributes? {
        if let e = statFailures[path] { errno = e; return nil }
        guard let n = nodes[path] else { errno = ENOENT; return nil }
        return n.attr
    }

    func children(of path: VolumePath) -> [VolumePath] {
        let prefix = path == .root ? path.bytes : path.bytes + [UInt8(ascii: "/")]
        return nodes.keys.filter { key in
            key != path && key.bytes.starts(with: prefix)
                && !key.bytes.dropFirst(prefix.count).contains(UInt8(ascii: "/"))
        }.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
    }

    func walkDirectory(_ path: VolumePath,
                       _ visit: (BcachefsDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk {
        guard let dir = nodes[path], dir.attr.fileType == .directory else {
            errno = nodes[path] == nil ? ENOENT : ENOTDIR
            return .openFailed
        }
        for child in children(of: path) {
            let n = nodes[child]!
            if !visit(BcachefsDirectoryEntry(name: child.lastComponent, inode: n.attr.inode,
                                             fileType: n.attr.fileType)) {
                break
            }
        }
        return .finished
    }

    func read(_ path: VolumePath, at offset: UInt64,
              into buffer: UnsafeMutableRawBufferPointer) -> Int64 {
        guard let n = nodes[path] else { errno = ENOENT; return -1 }
        let start = min(Int(offset), n.data.count)
        let count = min(buffer.count, n.data.count - start)
        for i in 0..<count { buffer[i] = n.data[start + i] }
        return Int64(count)
    }

    func readlink(_ path: VolumePath) -> [UInt8]? {
        guard let n = nodes[path] else { errno = ENOENT; return nil }
        guard let t = n.target else { errno = EINVAL; return nil }
        return t
    }

    func listXattrs(_ path: VolumePath) -> [[UInt8]]? {
        guard let n = nodes[path] else { errno = ENOENT; return nil }
        return n.xattrs.keys.sorted { $0.lexicographicallyPrecedes($1) }
    }

    func getXattr(_ path: VolumePath, name: [UInt8]) -> [UInt8]? {
        guard let n = nodes[path] else { errno = ENOENT; return nil }
        guard let v = n.xattrs[name] else { errno = ENOATTR; return nil }
        return v
    }

    private func write(_ call: Call, _ apply: () -> Int32) -> Int32 {
        calls.append(call)
        if let f = writeFailure { errno = -f; return f }
        let rc = apply()
        if rc < 0 { errno = -rc }
        return rc
    }

    func create(_ path: VolumePath, mode: UInt32) -> Int32 {
        write(.create(path.description, mode: mode)) {
            if nodes[path] != nil { return -EEXIST }
            add(path, mode: 0o100000 | mode)
            return 0
        }
    }

    func mkdir(_ path: VolumePath, mode: UInt32) -> Int32 {
        write(.mkdir(path.description, mode: mode)) {
            if nodes[path] != nil { return -EEXIST }
            add(path, mode: 0o040000 | mode)
            return 0
        }
    }

    func unlink(_ path: VolumePath) -> Int32 {
        write(.unlink(path.description)) { nodes.removeValue(forKey: path) == nil ? -ENOENT : 0 }
    }

    func rmdir(_ path: VolumePath) -> Int32 {
        write(.rmdir(path.description)) {
            if !children(of: path).isEmpty { return -ENOTEMPTY }
            return nodes.removeValue(forKey: path) == nil ? -ENOENT : 0
        }
    }

    func rename(_ from: VolumePath, to: VolumePath) -> Int32 {
        write(.rename(from.description, to.description)) {
            guard let n = nodes.removeValue(forKey: from) else { return -ENOENT }
            nodes[to] = n
            return 0
        }
    }

    func symlink(_ path: VolumePath, target: [UInt8]) -> Int32 {
        write(.symlink(path.description, target: target)) {
            add(path, mode: 0o120777, target: target)
            return 0
        }
    }

    func link(_ existing: VolumePath, to path: VolumePath) -> Int32 {
        write(.link(existing.description, path.description)) {
            guard var n = nodes[existing] else { return -ENOENT }
            n.attr.linkCount += 1
            nodes[existing] = n
            nodes[path] = n
            return 0
        }
    }

    func writeFile(_ path: VolumePath, _ bytes: UnsafeRawBufferPointer) -> Int32 {
        write(.writeFile(path.description, Array(bytes))) {
            guard var n = nodes[path] else { return -ENOENT }
            n.data = Array(bytes)
            n.attr.size = UInt64(bytes.count)
            nodes[path] = n
            return 0
        }
    }

    func chmod(_ path: VolumePath, mode: UInt32) -> Int32 {
        write(.chmod(path.description, mode: mode)) {
            guard var n = nodes[path] else { return -ENOENT }
            n.attr.mode = (n.attr.mode & 0o170000) | mode
            nodes[path] = n
            return 0
        }
    }

    func chown(_ path: VolumePath, uid: UInt32, gid: UInt32) -> Int32 {
        write(.chown(path.description, uid: uid, gid: gid)) {
            guard var n = nodes[path] else { return -ENOENT }
            (n.attr.uid, n.attr.gid) = (uid, gid)
            nodes[path] = n
            return 0
        }
    }

    func setXattr(_ path: VolumePath, name: [UInt8], value: [UInt8]) -> Int32 {
        write(.setXattr(path.description, name: name, value: value)) {
            guard nodes[path] != nil else { return -ENOENT }
            nodes[path]!.xattrs[name] = value
            return 0
        }
    }

    func removeXattr(_ path: VolumePath, name: [UInt8]) -> Int32 {
        write(.removeXattr(path.description, name: name)) {
            nodes[path]?.xattrs.removeValue(forKey: name) == nil ? -ENOENT : 0
        }
    }

    func lastErrno() -> Int32 { errno }
    func unmount() { unmounts += 1 }
}

private func makeVolume(_ b: TreeBackend, policy: BcachefsMountPolicy = .readWrite,
                        released: (() -> Void)? = nil) -> BcachefsVolume {
    BcachefsVolume(volumeID: FSVolume.Identifier(uuid: UUID()),
                   volumeName: FSFileName(string: "test"),
                   backend: b, policy: policy, bsdName: "disk9s1",
                   stats: IOStatsCollector(label: "test", emit: { _ in }),
                   releaseDevice: released)
}

private func code(_ body: () async throws -> Void) async -> POSIXErrorCode? {
    do { try await body(); return nil }
    catch let e as POSIXError { return e.code }
    catch { return nil }
}

private func name(_ s: String) -> FSFileName { FSFileName(string: s) }

/// The volume's item for a path the backend holds; its parent is the root
/// unless it is the root.
private func item(_ v: BcachefsVolume, _ b: TreeBackend, _ path: VolumePath,
                  parent: UInt64 = 4096) -> BcachefsItem {
    v.item(forInode: b.nodes[path]!.attr.inode, path: path,
           parentInode: path == .root ? nil : parent)
}

// MARK: - When a mount writes

@Suite("bcachefs mount policy")
struct BcachefsMountPolicyTests {

    @Test func aWritableDeviceMountsReadWriteWithNoOption() {
        #expect(BcachefsMountPolicy(deviceIsWritable: true, options: []) == .readWrite)
        #expect(BcachefsMountPolicy(deviceIsWritable: true, options: ["-o", "noatime"]) == .readWrite)
    }

    @Test func aReadOnlyDeviceNeverMountsReadWrite() {
        #expect(BcachefsMountPolicy(deviceIsWritable: false, options: []) == .readOnly)
        #expect(BcachefsMountPolicy(deviceIsWritable: false, options: ["rw"]) == .readOnly)
    }

    @Test func everySpellingOfReadOnlyIsHonoured() {
        for options in [["ro"], ["-o", "ro"], ["noatime,ro"], ["--rdonly"], ["rdonly"],
                        ["-r"], ["rw", "ro"], [" ro "]] {
            #expect(BcachefsMountPolicy(deviceIsWritable: true, options: options) == .readOnly,
                    "\(options)")
        }
    }

    @Test func anOptionThatOnlyContainsRoIsNotReadOnly() {
        #expect(BcachefsMountPolicy(deviceIsWritable: true,
                                    options: ["root=1", "errors=ro-continue"]) == .readWrite)
    }
}

// MARK: - Reading

@Suite("BcachefsVolume reading")
struct BcachefsVolumeReadingTests {

    @Test func theRootIsTheDriversRootInode() throws {
        let b = TreeBackend()
        let root = try makeVolume(b).rootItem()
        #expect(root.inode == 4096)
        #expect(root.volumePath == .root)
        #expect(root.parentInode == nil)
    }

    @Test func aRootThatCannotBeReadFailsTheMountWithTheDriversErrno() async {
        let b = TreeBackend()
        b.statFailures[.root] = EIO
        let v = makeVolume(b)
        #expect(await code { _ = try v.rootItem() } == .EIO)
    }

    @Test func attributesCoverFSKitsStandardSetFromTheDriversStat() async throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100640, data: Array(repeating: 7, count: 1000))
        b.nodes["/f"]!.attr.accessTime = BcachefsTime(seconds: 300, nanoseconds: 3)
        b.nodes["/f"]!.attr.modifyTime = BcachefsTime(seconds: 200, nanoseconds: 2)
        b.nodes["/f"]!.attr.changeTime = BcachefsTime(seconds: 250, nanoseconds: 5)
        b.nodes["/f"]!.attr.uid = 501
        let v = makeVolume(b)
        let a = try await v.attributes(FSItem.GetAttributesRequest(), of: item(v, b, "/f"))
        #expect(a.type == .file)
        #expect(a.mode == 0o640, "permission bits only: the type is `type`")
        #expect(a.uid == 501)
        #expect(a.size == 1000)
        #expect(a.allocSize == 1024, "two 512-byte sectors")
        #expect(a.linkCount == 1)
        #expect(a.fileID.rawValue == b.nodes["/f"]!.attr.inode)
        #expect(a.parentID.rawValue == 4096)
        #expect(a.modifyTime.tv_sec == 200 && a.modifyTime.tv_nsec == 2)
        #expect(a.accessTime.tv_sec == 300 && a.changeTime.tv_sec == 250)
        #expect(a.birthTime.tv_sec == 200, "the earliest time the driver reports")
    }

    @Test func theRootsParentIsFSKitsParentOfRoot() async throws {
        let b = TreeBackend()
        let v = makeVolume(b)
        let a = try await v.attributes(FSItem.GetAttributesRequest(), of: try v.rootItem())
        #expect(a.parentID == .parentOfRoot)
    }

    @Test func aFailedStatIsTheDriversErrnoNotENOENT() async {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644)
        b.statFailures["/f"] = EIO
        let v = makeVolume(b)
        let f = v.item(forInode: 1, path: "/f", parentInode: 4096)
        #expect(await code { _ = try await v.attributes(FSItem.GetAttributesRequest(), of: f) } == .EIO)
    }

    @Test func lookupOfAMissingNameIsENOENT() async throws {
        let b = TreeBackend()
        let v = makeVolume(b)
        let root = try v.rootItem()
        #expect(await code { _ = try await v.lookupItem(named: name("nope"), inDirectory: root) } == .ENOENT)
    }

    @Test func aNameThatIsNotUTF8IsRefusedBeforeTheDriverSeesIt() async throws {
        let b = TreeBackend()
        let v = makeVolume(b)
        let root = try v.rootItem()
        let bad = FSFileName(data: Data([0x63, 0x61, 0x66, 0xE9]))
        #expect(await code { _ = try await v.lookupItem(named: bad, inDirectory: root) } == .EILSEQ)
    }

    @Test func listingPacksEveryEntryWithItsTypeAndResumesFromTheCookie() throws {
        let b = TreeBackend()
        b.add("/a", mode: 0o100644)
        b.add("/b", mode: 0o040755)
        b.add("/c", mode: 0o120777, target: Array("a".utf8))
        let v = makeVolume(b)
        let root = try v.rootItem()
        var packed: [PackableDirectoryEntry] = []
        let end = try v.entries(of: root, after: 0, withAttributes: true) { packed.append($0); return true }
        #expect(packed.map { $0.name.string } == ["a", "b", "c"])
        #expect(packed.map(\.itemType) == [.file, .directory, .symlink])
        #expect(packed.allSatisfy { $0.attributes != nil })
        #expect(end == 4)
        var rest: [String?] = []
        _ = try v.entries(of: root, after: 2, withAttributes: false) { rest.append($0.name.string); return true }
        #expect(rest == ["c"])
    }

    @Test func aSubvolumeIsNeverListedUnderOneOfFSKitsOwnIdentifiers() {
        // fs_bcachefs.h: a subvolume's dirent carries the subvolume id.
        for id: UInt64 in [1, 2, 3] {
            let entry = BcachefsDirectoryEntry(name: Array("sv".utf8), inode: id, fileType: .subvolume)
            let listed = BcachefsVolume.listedID(entry)
            #expect(listed > UInt64(Int64.max), "\(id) -> \(listed)")
            #expect(FSItem.Identifier(rawValue: listed) != .rootDirectory)
        }
        let file = BcachefsDirectoryEntry(name: Array("f".utf8), inode: 4097, fileType: .file)
        #expect(BcachefsVolume.listedID(file) == 4097)
    }

    @Test func aDirectoryThatCannotBeOpenedIsTheDriversErrno() async throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644)
        let v = makeVolume(b)
        let f = v.item(forInode: 9, path: "/f", parentInode: 4096)
        #expect(await code { _ = try v.entries(of: f, after: 0, withAttributes: false) { _ in true } } == .ENOTDIR)
    }

    @Test func aReadAnswersTheBytesAndZeroAtTheEnd() throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644, data: Array("hello".utf8))
        let v = makeVolume(b)
        let f = item(v, b, "/f")
        var buf = [UInt8](repeating: 0, count: 8)
        let n = try buf.withUnsafeMutableBytes { try v.readBytes(from: f, at: 1, into: $0) }
        #expect(n == 4 && Array(buf.prefix(4)) == Array("ello".utf8))
        let atEnd = try buf.withUnsafeMutableBytes { try v.readBytes(from: f, at: 5, into: $0) }
        #expect(atEnd == 0)
    }

    @Test func aFailedReadIsAnErrorNeverAShortFile() async throws {
        let b = TreeBackend()
        let v = makeVolume(b)
        let gone = v.item(forInode: 9, path: "/gone", parentInode: 4096)
        var buf = [UInt8](repeating: 0, count: 4)
        #expect(await code { _ = try buf.withUnsafeMutableBytes { try v.readBytes(from: gone, at: 0, into: $0) } } == .ENOENT)
    }

    @Test func aSymlinksTargetIsItsBytes() async throws {
        let b = TreeBackend()
        b.add("/l", mode: 0o120777, target: [0x61, 0xFF, 0x62])
        let v = makeVolume(b)
        let t = try await v.readSymbolicLink(item(v, b, "/l"))
        #expect([UInt8](t.data) == [0x61, 0xFF, 0x62])
    }

    @Test func statfsCountsBlocksOfTheBlockSizeAndOffersFreeSpaceOnlyWhenWritable() {
        let info = BcachefsVolumeInfo(blockSize: 4096, bucketSize: 131072,
                                      totalBytes: 64 << 20, freeBytes: 60 << 20)
        let rw = BcachefsVolume.statFS(info, writable: true)
        #expect(rw.blockSize == 4096)
        #expect(rw.ioSize == 131072)
        #expect(rw.totalBlocks == 16384)
        #expect(rw.freeBlocks == 15360)
        #expect(rw.availableBlocks == 15360)
        #expect(rw.fileSystemTypeName == "bcachefs")
        let ro = BcachefsVolume.statFS(info, writable: false)
        #expect(ro.freeBlocks == 15360 && ro.availableBlocks == 0)
        let unknown = BcachefsVolume.statFS(nil, writable: true)
        #expect(unknown.totalBlocks == 0 && unknown.availableBlocks == 0)
    }

    @Test func freeSpaceThatExceedsTheTotalIsClampedNotWrapped() {
        let info = BcachefsVolumeInfo(blockSize: 512, bucketSize: 512,
                                      totalBytes: 1024, freeBytes: 4096)
        let s = BcachefsVolume.statFS(info, writable: true)
        #expect(s.freeBlocks == 2 && s.totalBlocks == 2)
    }
}

// MARK: - Writing

@Suite("BcachefsVolume writing")
struct BcachefsVolumeWritingTests {

    @Test func aReadOnlyMountRefusesEveryWriteWithEROFSAndCallsNothing() async throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644, data: Array("x".utf8))
        b.add("/d", mode: 0o040755)
        let v = makeVolume(b, policy: .readOnly)
        let root = try v.rootItem()
        let f = item(v, b, "/f")
        let req = FSItem.SetAttributesRequest()
        req.mode = 0o600
        #expect(await code { _ = try await v.createItem(named: name("n"), type: .file, inDirectory: root, attributes: FSItem.SetAttributesRequest()) } == .EROFS)
        #expect(await code { _ = try await v.createSymbolicLink(named: name("l"), inDirectory: root, attributes: FSItem.SetAttributesRequest(), linkContents: name("f")) } == .EROFS)
        #expect(await code { _ = try await v.createLink(to: f, named: name("h"), inDirectory: root) } == .EROFS)
        #expect(await code { try await v.removeItem(f, named: name("f"), fromDirectory: root) } == .EROFS)
        #expect(await code { _ = try await v.renameItem(f, inDirectory: root, named: name("f"), to: name("g"), inDirectory: root, overItem: nil) } == .EROFS)
        #expect(await code { _ = try await v.write(contents: Data("y".utf8), to: f, at: 0) } == .EROFS)
        #expect(await code { _ = try await v.setAttributes(req, on: f) } == .EROFS)
        #expect(await code { try await v.setXattr(named: name("a"), to: Data("v".utf8), on: f, policy: .alwaysSet) } == .EROFS)
        #expect(b.calls.isEmpty)
        #expect(v.supportedVolumeCapabilities.doesNotSupportSettingFilePermissions)
    }

    @Test func aDriverWithoutAWriteHandleMakesTheMountReadOnly() async throws {
        let b = TreeBackend()
        b.isWritable = false
        let v = makeVolume(b, policy: .readWrite)
        #expect(!v.allowsWrites)
        let root = try v.rootItem()
        #expect(await code { _ = try await v.createItem(named: name("n"), type: .file, inDirectory: root, attributes: FSItem.SetAttributesRequest()) } == .EROFS)
    }

    @Test func aReadOnlyOptionAfterLoadTurnsTheMountReadOnlyForGood() {
        let b = TreeBackend()
        let v = makeVolume(b)
        #expect(v.allowsWrites)
        v.applyMountOptions(["-o", "ro"])
        #expect(!v.allowsWrites)
        v.applyMountOptions(["rw"])
        #expect(!v.allowsWrites)
    }

    @Test func creatingAFileOrDirectoryUsesTheRequestedOrDefaultMode() async throws {
        let b = TreeBackend()
        let v = makeVolume(b)
        let root = try v.rootItem()
        let req = FSItem.SetAttributesRequest()
        req.mode = 0o100600
        _ = try await v.createItem(named: name("f"), type: .file, inDirectory: root, attributes: req)
        #expect(req.consumedAttributes.contains(.mode))
        _ = try await v.createItem(named: name("g"), type: .file, inDirectory: root, attributes: FSItem.SetAttributesRequest())
        let (d, _) = try await v.createItem(named: name("d"), type: .directory, inDirectory: root, attributes: FSItem.SetAttributesRequest())
        #expect(b.calls == [.create("/f", mode: 0o600), .create("/g", mode: 0o644), .mkdir("/d", mode: 0o755)])
        #expect((d as? BcachefsItem)?.volumePath == "/d")
        #expect((d as? BcachefsItem)?.parentInode == 4096)
    }

    @Test func anOwnerAskedForAtCreateIsSet() async throws {
        let b = TreeBackend()
        let v = makeVolume(b)
        let req = FSItem.SetAttributesRequest()
        req.uid = 501
        _ = try await v.createItem(named: name("f"), type: .file, inDirectory: try v.rootItem(), attributes: req)
        #expect(b.calls.last == .chown("/f", uid: 501, gid: 0))
        #expect(req.consumedAttributes.contains(.uid))
        #expect(!req.consumedAttributes.contains(.gid))
    }

    @Test func devicesFifosAndSocketsAreNotSupported() async throws {
        let b = TreeBackend()
        let v = makeVolume(b)
        let root = try v.rootItem()
        for type: FSItem.ItemType in [.fifo, .charDevice, .blockDevice, .socket] {
            #expect(await code { _ = try await v.createItem(named: name("x"), type: type, inDirectory: root, attributes: FSItem.SetAttributesRequest()) } == .ENOTSUP)
        }
        #expect(b.calls.isEmpty)
    }

    @Test func aCreateTheDriverRefusesIsItsErrno() async throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644)
        let v = makeVolume(b)
        #expect(await code { _ = try await v.createItem(named: name("f"), type: .file, inDirectory: try v.rootItem(), attributes: FSItem.SetAttributesRequest()) } == .EEXIST)
        b.writeFailure = -ENOSPC
        #expect(await code { _ = try await v.createItem(named: name("g"), type: .directory, inDirectory: try v.rootItem(), attributes: FSItem.SetAttributesRequest()) } == .ENOSPC)
    }

    @Test func removingAFileUnlinksAndADirectoryRmdirs() async throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644)
        b.add("/d", mode: 0o040755)
        let v = makeVolume(b)
        let root = try v.rootItem()
        try await v.removeItem(item(v, b, "/f"), named: name("f"), fromDirectory: root)
        try await v.removeItem(item(v, b, "/d"), named: name("d"), fromDirectory: root)
        #expect(b.calls == [.unlink("/f"), .rmdir("/d")])
    }

    @Test func removingADirectoryThatIsNotEmptyIsENOTEMPTY() async throws {
        let b = TreeBackend()
        b.add("/d", mode: 0o040755)
        b.add("/d/f", mode: 0o100644)
        let v = makeVolume(b)
        #expect(await code { try await v.removeItem(item(v, b, "/d"), named: name("d"), fromDirectory: try v.rootItem()) } == .ENOTEMPTY)
    }

    @Test func renameAsksTheDriverOnceAndUnlinksNothingFirst() async throws {
        let b = TreeBackend()
        b.add("/a", mode: 0o100644)
        b.add("/b", mode: 0o100644)
        b.add("/d", mode: 0o040755)
        let v = makeVolume(b)
        let root = try v.rootItem()
        let d = item(v, b, "/d")
        _ = try await v.renameItem(item(v, b, "/a"), inDirectory: root, named: name("a"),
                                   to: name("x"), inDirectory: d, overItem: nil)
        _ = try await v.renameItem(item(v, b, "/b"), inDirectory: root, named: name("b"),
                                   to: name("x"), inDirectory: d, overItem: nil)
        #expect(b.calls == [.rename("/a", "/d/x"), .rename("/b", "/d/x")])
    }

    @Test func symlinksAndHardLinksReachTheDriver() async throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644)
        let v = makeVolume(b)
        let root = try v.rootItem()
        _ = try await v.createSymbolicLink(named: name("l"), inDirectory: root,
                                           attributes: FSItem.SetAttributesRequest(),
                                           linkContents: FSFileName(data: Data([0x66, 0xFF])))
        _ = try await v.createLink(to: item(v, b, "/f"), named: name("h"), inDirectory: root)
        #expect(b.calls == [.symlink("/l", target: [0x66, 0xFF]), .link("/f", "/h")])
    }

    @Test func anEmptySymlinkTargetIsEINVAL() async throws {
        let b = TreeBackend()
        let v = makeVolume(b)
        let root = try v.rootItem()
        #expect(await code { _ = try await v.createSymbolicLink(named: name("l"), inDirectory: root, attributes: FSItem.SetAttributesRequest(), linkContents: FSFileName(data: Data())) } == .EINVAL)
        #expect(b.calls.isEmpty)
    }

    @Test func aWriteFromTheStartCoveringTheFileReplacesItWithoutReading() async throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644, data: Array("old".utf8))
        let v = makeVolume(b)
        let n = try await v.write(contents: Data("brand new".utf8), to: item(v, b, "/f"), at: 0)
        #expect(n == 9)
        #expect(b.calls == [.writeFile("/f", Array("brand new".utf8))])
    }

    @Test func aWriteAtAnOffsetSplicesIntoTheWholeFile() async throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644, data: Array("hello world".utf8))
        let v = makeVolume(b)
        let n = try await v.write(contents: Data("WORLD".utf8), to: item(v, b, "/f"), at: 6)
        #expect(n == 5)
        #expect(b.nodes["/f"]!.data == Array("hello WORLD".utf8))
    }

    @Test func aWritePastTheEndFillsTheGapWithZeros() async throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644, data: Array("ab".utf8))
        let v = makeVolume(b)
        _ = try await v.write(contents: Data("z".utf8), to: item(v, b, "/f"), at: 4)
        #expect(b.nodes["/f"]!.data == [0x61, 0x62, 0, 0, 0x7A])
    }

    @Test func anEmptyWriteChangesNothing() async throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644, data: Array("ab".utf8))
        let v = makeVolume(b)
        #expect(try await v.write(contents: Data(), to: item(v, b, "/f"), at: 10) == 0)
        #expect(b.calls.isEmpty)
    }

    @Test func aRefusedWriteIsTheDriversErrno() async throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644, data: Array("ab".utf8))
        b.writeFailure = -ENOSPC
        let v = makeVolume(b)
        #expect(await code { _ = try await v.write(contents: Data("xyz".utf8), to: item(v, b, "/f"), at: 0) } == .ENOSPC)
    }

    @Test func aSizeChangeKeepsTheBytesBelowItAndZeroFillsAbove() async throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644, data: Array("hello".utf8))
        let v = makeVolume(b)
        let f = item(v, b, "/f")
        let shrink = FSItem.SetAttributesRequest()
        shrink.size = 2
        let a = try await v.setAttributes(shrink, on: f)
        #expect(b.nodes["/f"]!.data == Array("he".utf8))
        #expect(a.size == 2)
        #expect(shrink.consumedAttributes == [.size])
        let grow = FSItem.SetAttributesRequest()
        grow.size = 4
        _ = try await v.setAttributes(grow, on: f)
        #expect(b.nodes["/f"]!.data == [0x68, 0x65, 0, 0])
    }

    @Test func modeAndOwnerAreSetAndTimesAreLeftUnconsumed() async throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644)
        b.nodes["/f"]!.attr.uid = 7
        b.nodes["/f"]!.attr.gid = 8
        let v = makeVolume(b)
        let req = FSItem.SetAttributesRequest()
        req.mode = 0o100600
        req.gid = 20
        req.modifyTime = timespec(tv_sec: 1, tv_nsec: 0)
        let a = try await v.setAttributes(req, on: item(v, b, "/f"))
        #expect(b.calls == [.chmod("/f", mode: 0o600), .chown("/f", uid: 7, gid: 20)])
        #expect(req.consumedAttributes == [.mode, .gid])
        #expect(a.mode == 0o600 && a.gid == 20 && a.uid == 7)
    }
}

// MARK: - Extended attributes

@Suite("BcachefsVolume extended attributes")
struct BcachefsVolumeXattrTests {

    @Test func aMacNameIsTheUserNamespacesAndOnlyThatNamespaceIsListed() async throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644)
        b.nodes["/f"]!.xattrs = [
            Array("user.colour".utf8): Array("blue".utf8),
            Array("trusted.secret".utf8): Array("x".utf8),
            Array("security.selinux".utf8): Array("y".utf8),
            Array("user.com.apple.FinderInfo".utf8): [1, 2, 3],
        ]
        let v = makeVolume(b)
        let f = item(v, b, "/f")
        let names = try await v.xattrs(of: f).compactMap(\.string).sorted()
        #expect(names == ["colour", "com.apple.FinderInfo"])
        #expect(try await v.xattr(named: name("colour"), of: f) == Data("blue".utf8))
        #expect(await code { _ = try await v.xattr(named: name("nothing"), of: f) } == .ENOATTR)
    }

    @Test func settingWritesTheUserNamespacedName() async throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644)
        let v = makeVolume(b)
        try await v.setXattr(named: name("com.apple.FinderInfo"), to: Data([9]), on: item(v, b, "/f"), policy: .alwaysSet)
        #expect(b.calls == [.setXattr("/f", name: Array("user.com.apple.FinderInfo".utf8), value: [9])])
    }

    @Test func thePoliciesAreJudgedOnWhetherTheAttributeIsThere() async throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644)
        b.nodes["/f"]!.xattrs[Array("user.a".utf8)] = [1]
        let v = makeVolume(b)
        let f = item(v, b, "/f")
        #expect(await code { try await v.setXattr(named: name("a"), to: Data([2]), on: f, policy: .mustCreate) } == .EEXIST)
        #expect(await code { try await v.setXattr(named: name("b"), to: Data([2]), on: f, policy: .mustReplace) } == .ENOATTR)
        #expect(await code { try await v.setXattr(named: name("b"), to: nil, on: f, policy: .delete) } == .ENOATTR)
        #expect(b.calls.isEmpty, "a refused policy writes nothing")
        try await v.setXattr(named: name("a"), to: Data([3]), on: f, policy: .mustReplace)
        try await v.setXattr(named: name("b"), to: Data([4]), on: f, policy: .mustCreate)
        try await v.setXattr(named: name("a"), to: nil, on: f, policy: .delete)
        #expect(b.calls == [
            .setXattr("/f", name: Array("user.a".utf8), value: [3]),
            .setXattr("/f", name: Array("user.b".utf8), value: [4]),
            .removeXattr("/f", name: Array("user.a".utf8)),
        ])
    }

    @Test func anEmptyNameIsEINVAL() async throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644)
        let v = makeVolume(b)
        let f = item(v, b, "/f")
        #expect(await code { _ = try await v.xattr(named: FSFileName(data: Data()), of: f) } == .EINVAL)
    }

    @Test func theNameMappingRoundTripsAndRefusesOtherNamespaces() {
        #expect(BcachefsVolume.macXattrName(Array("user.x".utf8)) == Array("x".utf8))
        #expect(BcachefsVolume.macXattrName(Array("user.".utf8)) == nil)
        #expect(BcachefsVolume.macXattrName(Array("trusted.x".utf8)) == nil)
        #expect(BcachefsVolume.macXattrName(Array("userx".utf8)) == nil)
    }
}

// MARK: - Lifecycle

@Suite("BcachefsVolume lifecycle")
struct BcachefsVolumeLifecycleTests {

    @Test func shuttingDownUnmountsOnceThenReleasesTheDevice() {
        let b = TreeBackend()
        var released = 0
        let v = makeVolume(b, released: { released += 1 })
        v.shutDown()
        v.shutDown()
        #expect(b.unmounts == 1)
        #expect(released == 1)
    }

    @Test func afterShutdownEveryOperationIsEBADF() async throws {
        let b = TreeBackend()
        b.add("/f", mode: 0o100644)
        let v = makeVolume(b)
        let f = item(v, b, "/f")
        v.shutDown()
        #expect(await code { _ = try await v.attributes(FSItem.GetAttributesRequest(), of: f) } == .EBADF)
        #expect(await code { _ = try await v.write(contents: Data("x".utf8), to: f, at: 0) } == .EBADF)
    }

    @Test func theCapabilitiesAreBcachefss() {
        let caps = makeVolume(TreeBackend()).supportedVolumeCapabilities
        #expect(caps.supportsHardLinks && caps.supportsSymbolicLinks)
        #expect(caps.supports64BitObjectIDs)
        #expect(caps.caseFormat == .sensitive)
        #expect(!caps.doesNotSupportSettingFilePermissions)
    }
}
