//
//  XfsNamespaceTests.swift — FSKit create, remove, rename and link on XFS
//  (diskjockey#326, #327).
//
//  The volume made every namespace change answer ENOTSUP. rust-fs-xfs 0.13's
//  C ABI makes each one in a logged record: fs_xfs_create, fs_xfs_mkdir,
//  fs_xfs_unlink, fs_xfs_rmdir, fs_xfs_link and fs_xfs_rename2. These tests
//  hold the volume to calling the right one with the right path and mode,
//  to handing FSKit the item the driver made, and to answering every refusal
//  with the driver's own errno. The stand-in below refuses exactly as
//  fs_xfs.h says the driver does.
//

import Foundation
import FSKit
import Testing
@testable import DiskJockeyXFSCore
import DiskJockeyLibrary

/// An in-memory XFS namespace with the 0.13 C ABI's refusals.
private final class NamespaceDriver: XfsMountedVolumeDriver {
    enum Node { case file, directory }

    var isWritable = true
    var errno: Int32 = 0
    private(set) var nodes: [VolumePath: (inode: UInt64, kind: Node)] = [.root: (64, .directory)]
    private var nextInode: UInt64 = 128
    /// Every namespace call, in order, as "op path [path] [mode/flags]".
    private(set) var calls: [String] = []
    /// Every set_attributes call: path, mode, uid, gid (nil = left alone).
    private(set) var attributeCalls: [(VolumePath, UInt32?, UInt32?, UInt32?)] = []

    private func parent(_ path: VolumePath) -> VolumePath {
        let bytes = path.bytes
        guard let slash = bytes.lastIndex(of: UInt8(ascii: "/")), slash > 0 else { return .root }
        return VolumePath(bytes: Array(bytes[..<slash]))
    }

    private func children(_ path: VolumePath) -> [VolumePath] {
        nodes.keys.filter { $0 != .root && parent($0) == path }
    }

    private func make(_ path: VolumePath, _ kind: Node) -> UInt64 {
        guard nodes[path] == nil else { errno = EEXIST; return 0 }
        guard let p = nodes[parent(path)] else { errno = ENOENT; return 0 }
        guard p.kind == .directory else { errno = ENOTDIR; return 0 }
        nextInode += 1
        nodes[path] = (nextInode, kind)
        return nextInode
    }

    func create(_ path: VolumePath, mode: UInt16) -> UInt64 {
        calls.append("create \(path) \(String(mode, radix: 8))")
        return make(path, .file)
    }

    func mkdir(_ path: VolumePath, mode: UInt16) -> UInt64 {
        calls.append("mkdir \(path) \(String(mode, radix: 8))")
        return make(path, .directory)
    }

    func unlink(_ path: VolumePath) -> Int32 {
        calls.append("unlink \(path)")
        guard let n = nodes[path] else { errno = ENOENT; return -1 }
        guard n.kind != .directory else { errno = EISDIR; return -1 }
        nodes[path] = nil
        return 0
    }

    func rmdir(_ path: VolumePath) -> Int32 {
        calls.append("rmdir \(path)")
        guard let n = nodes[path] else { errno = ENOENT; return -1 }
        guard n.kind == .directory else { errno = ENOTDIR; return -1 }
        guard children(path).isEmpty else { errno = ENOTEMPTY; return -1 }
        nodes[path] = nil
        return 0
    }

    func link(_ source: VolumePath, to destination: VolumePath) -> Int32 {
        calls.append("link \(source) \(destination)")
        guard let n = nodes[source] else { errno = ENOENT; return -1 }
        guard n.kind != .directory else { errno = EPERM; return -1 }
        guard nodes[destination] == nil else { errno = EEXIST; return -1 }
        nodes[destination] = n
        return 0
    }

    func rename(_ source: VolumePath, to destination: VolumePath, replace: Bool) -> Int32 {
        calls.append("rename \(source) \(destination) \(replace ? "replace" : "noreplace")")
        guard let n = nodes[source] else { errno = ENOENT; return -1 }
        if let d = nodes[destination] {
            guard replace else { errno = EEXIST; return -1 }
            if n.kind == .file && d.kind == .directory { errno = EISDIR; return -1 }
            if n.kind == .directory && d.kind == .file { errno = ENOTDIR; return -1 }
            if d.kind == .directory && !children(destination).isEmpty { errno = ENOTEMPTY; return -1 }
        }
        nodes[source] = nil
        nodes[destination] = n
        return 0
    }

    func setAttributes(_ path: VolumePath, mode: UInt32?, uid: UInt32?, gid: UInt32?,
                       accessed: timespec?, modified: timespec?) -> Int32 {
        attributeCalls.append((path, mode, uid, gid))
        guard nodes[path] != nil else { errno = ENOENT; return -1 }
        return 0
    }

    func stat(_ path: VolumePath) -> ReadOnlyFileAttributes? {
        guard let n = nodes[path] else { errno = ENOENT; return nil }
        return ReadOnlyFileAttributes(
            inode: n.inode, mode: n.kind == .directory ? 0o40755 : 0o100644,
            uid: 0, gid: 0, size: 0, linkCount: 1, mtime: 0,
            fileType: n.kind == .directory ? .directory : .file)
    }

    func volumeInfo() -> ReadOnlyVolumeInfo? { nil }
    func walkDirectory(_ path: VolumePath,
                       _ visit: (ReadOnlyDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk { .finished }
    func read(_ path: VolumePath, at offset: UInt64,
              into buffer: UnsafeMutableRawBufferPointer) -> Int64 { 0 }
    func write(_ path: VolumePath, at offset: UInt64,
               from buffer: UnsafeRawBufferPointer) -> Int64 { -1 }
    func truncate(_ path: VolumePath, to size: UInt64, modified: timespec?) -> Int32 { -1 }
    func flush() -> Int32 { 0 }
    func readlink(_ path: VolumePath, _ buffer: UnsafeMutablePointer<CChar>, _ size: Int) -> Int32 { -1 }
    func lastErrno() -> Int32 { errno }
    func unmount() { isWritable = false }
}

private func p(_ s: String) -> VolumePath { VolumePath(bytes: Array(s.utf8)) }
private func name(_ s: String) -> FSFileName { FSFileName(string: s) }

private func fixture(writable: Bool = true) throws -> (XfsVolume, NamespaceDriver, XfsItem) {
    let driver = NamespaceDriver()
    let access = writable
        ? try XfsMountPolicy.readWrite.authorize(deviceIsWritable: true, mountedDriver: .success(true))
        : .readOnly
    let volume = XfsVolume(volumeID: FSVolume.Identifier(), volumeName: FSFileName(string: "ns"),
                           driver: driver, contextPtr: nil, bsdName: "namespace-test",
                           stats: IOStatsCollector(label: "namespace-test", emit: { _ in }),
                           mountAccess: access)
    return (volume, driver, try volume.rootItem())
}

private func code(_ body: () async throws -> Void) async -> POSIXErrorCode? {
    do { try await body(); return nil } catch let e as POSIXError { return e.code } catch { return nil }
}

@Suite("XFS FSKit create, remove, rename and link")
struct XfsNamespaceTests {

    @Test func aFileIsCreatedWithTheDefaultModeAndIsTheDriversInode() async throws {
        let (volume, driver, root) = try fixture()
        let (made, madeName) = try await volume.createItem(
            named: name("a"), type: .file, inDirectory: root, attributes: FSItem.SetAttributesRequest())
        #expect(driver.calls == ["create /a 644"])
        #expect((made as? XfsItem)?.inode == driver.nodes[p("/a")]?.inode)
        #expect((made as? XfsItem)?.volumePath == p("/a"))
        #expect(madeName.string == "a")
    }

    @Test func aDirectoryIsMadeWithTheModeAskedFor() async throws {
        let (volume, driver, root) = try fixture()
        let request = FSItem.SetAttributesRequest()
        request.mode = 0o700
        _ = try await volume.createItem(named: name("d"), type: .directory, inDirectory: root,
                                        attributes: request)
        #expect(driver.calls == ["mkdir /d 700"])
        #expect(request.consumedAttributes.contains(.mode))
    }

    /// The new inode belongs to uid 0 (fs_xfs.h); an owner asked for at
    /// create is set right after, in its own call.
    @Test func anOwnerAskedForAtCreateIsSet() async throws {
        let (volume, driver, root) = try fixture()
        let request = FSItem.SetAttributesRequest()
        request.uid = 501
        request.gid = 20
        _ = try await volume.createItem(named: name("o"), type: .file, inDirectory: root,
                                        attributes: request)
        #expect(driver.attributeCalls.count == 1)
        #expect(driver.attributeCalls.first?.0 == p("/o"))
        #expect(driver.attributeCalls.first?.2 == 501)
        #expect(driver.attributeCalls.first?.3 == 20)
        #expect(request.consumedAttributes.contains(.uid))
        #expect(request.consumedAttributes.contains(.gid))
    }

    @Test func aTakenNameIsTheDriversEEXIST() async throws {
        let (volume, driver, root) = try fixture()
        _ = driver.create(p("/a"), mode: 0o644)
        #expect(await code {
            _ = try await volume.createItem(named: name("a"), type: .file, inDirectory: root,
                                            attributes: FSItem.SetAttributesRequest())
        } == .EEXIST)
    }

    /// The C ABI makes regular files and directories; a device, fifo or
    /// socket has no call to make it.
    @Test(arguments: [FSItem.ItemType.fifo, .socket, .charDevice, .blockDevice])
    func anotherTypeIsENOTSUP(_ type: FSItem.ItemType) async throws {
        let (volume, driver, root) = try fixture()
        #expect(await code {
            _ = try await volume.createItem(named: name("x"), type: type, inDirectory: root,
                                            attributes: FSItem.SetAttributesRequest())
        } == .ENOTSUP)
        #expect(driver.calls.isEmpty)
    }

    /// rust-fs-xfs makes no symlink (docs/features.md: "Create a symlink:
    /// Not supported"), so FSKit is told so, and nothing is written.
    @Test func aSymlinkIsENOTSUP() async throws {
        let (volume, driver, root) = try fixture()
        #expect(await code {
            _ = try await volume.createSymbolicLink(named: name("l"), inDirectory: root,
                                                   attributes: FSItem.SetAttributesRequest(),
                                                   linkContents: name("a"))
        } == .ENOTSUP)
        #expect(driver.calls.isEmpty)
    }

    @Test func aFileIsUnlinkedAndADirectoryRemoved() async throws {
        let (volume, driver, root) = try fixture()
        _ = driver.create(p("/f"), mode: 0o644)
        _ = driver.mkdir(p("/d"), mode: 0o755)
        let f = volume.item(forInode: driver.nodes[p("/f")]!.inode, path: p("/f"), parentInode: 64)
        let d = volume.item(forInode: driver.nodes[p("/d")]!.inode, path: p("/d"), parentInode: 64)
        try await volume.removeItem(f, named: name("f"), fromDirectory: root)
        try await volume.removeItem(d, named: name("d"), fromDirectory: root)
        #expect(Array(driver.calls.suffix(2)) == ["unlink /f", "rmdir /d"])
        #expect(driver.nodes[p("/f")] == nil && driver.nodes[p("/d")] == nil)
    }

    @Test func aDirectoryThatHoldsANameIsTheDriversENOTEMPTY() async throws {
        let (volume, driver, root) = try fixture()
        _ = driver.mkdir(p("/d"), mode: 0o755)
        _ = driver.create(p("/d/f"), mode: 0o644)
        let d = volume.item(forInode: driver.nodes[p("/d")]!.inode, path: p("/d"), parentInode: 64)
        #expect(await code { try await volume.removeItem(d, named: name("d"), fromDirectory: root) } == .ENOTEMPTY)
        #expect(driver.nodes[p("/d")] != nil)
    }

    /// rename(2) replaces a name that is there, and FSKit passes the item
    /// it replaces only when the kernel had already resolved it, so the
    /// volume always asks the driver to replace: FS_XFS_RENAME_REPLACE.
    @Test func aRenameReplacesAsRename2Does() async throws {
        let (volume, driver, root) = try fixture()
        _ = driver.create(p("/a"), mode: 0o644)
        _ = driver.create(p("/b"), mode: 0o644)
        let a = volume.item(forInode: driver.nodes[p("/a")]!.inode, path: p("/a"), parentInode: 64)
        let renamed = try await volume.renameItem(a, inDirectory: root, named: name("a"),
                                                  to: name("b"), inDirectory: root, overItem: nil)
        #expect(renamed.string == "b")
        #expect(driver.calls.last == "rename /a /b replace")
        #expect(driver.nodes[p("/a")] == nil)
        #expect(driver.nodes[p("/b")]?.inode == a.inode)
    }

    @Test func aRenameAcrossDirectoriesNamesBothPaths() async throws {
        let (volume, driver, root) = try fixture()
        _ = driver.mkdir(p("/d"), mode: 0o755)
        _ = driver.create(p("/a"), mode: 0o644)
        let a = volume.item(forInode: driver.nodes[p("/a")]!.inode, path: p("/a"), parentInode: 64)
        let d = volume.item(forInode: driver.nodes[p("/d")]!.inode, path: p("/d"), parentInode: 64)
        _ = try await volume.renameItem(a, inDirectory: root, named: name("a"),
                                        to: name("z"), inDirectory: d, overItem: nil)
        #expect(driver.calls.last == "rename /a /d/z replace")
    }

    @Test func aFileOverADirectoryIsTheDriversEISDIR() async throws {
        let (volume, driver, root) = try fixture()
        _ = driver.create(p("/a"), mode: 0o644)
        _ = driver.mkdir(p("/d"), mode: 0o755)
        let a = volume.item(forInode: driver.nodes[p("/a")]!.inode, path: p("/a"), parentInode: 64)
        #expect(await code {
            _ = try await volume.renameItem(a, inDirectory: root, named: name("a"),
                                            to: name("d"), inDirectory: root, overItem: nil)
        } == .EISDIR)
        #expect(driver.nodes[p("/a")] != nil)
    }

    @Test func aHardLinkIsASecondName() async throws {
        let (volume, driver, root) = try fixture()
        _ = driver.create(p("/a"), mode: 0o644)
        let a = volume.item(forInode: driver.nodes[p("/a")]!.inode, path: p("/a"), parentInode: 64)
        let linked = try await volume.createLink(to: a, named: name("h"), inDirectory: root)
        #expect(linked.string == "h")
        #expect(driver.calls.last == "link /a /h")
        #expect(driver.nodes[p("/h")]?.inode == a.inode)
    }

    @Test func aHardLinkToADirectoryIsTheDriversEPERM() async throws {
        let (volume, driver, root) = try fixture()
        _ = driver.mkdir(p("/d"), mode: 0o755)
        let d = volume.item(forInode: driver.nodes[p("/d")]!.inode, path: p("/d"), parentInode: 64)
        #expect(await code { _ = try await volume.createLink(to: d, named: name("h"), inDirectory: root) } == .EPERM)
    }

    /// A read-only mount answers every namespace change with EROFS and
    /// never calls the driver.
    @Test func aReadOnlyMountChangesNothing() async throws {
        let (volume, driver, root) = try fixture(writable: false)
        let f = volume.item(forInode: 200, path: p("/f"), parentInode: 64)
        #expect(await code { _ = try await volume.createItem(named: name("n"), type: .file, inDirectory: root, attributes: FSItem.SetAttributesRequest()) } == .EROFS)
        #expect(await code { _ = try await volume.createSymbolicLink(named: name("l"), inDirectory: root, attributes: FSItem.SetAttributesRequest(), linkContents: name("f")) } == .EROFS)
        #expect(await code { _ = try await volume.createLink(to: f, named: name("h"), inDirectory: root) } == .EROFS)
        #expect(await code { try await volume.removeItem(f, named: name("f"), fromDirectory: root) } == .EROFS)
        #expect(await code { _ = try await volume.renameItem(f, inDirectory: root, named: name("f"), to: name("g"), inDirectory: root, overItem: nil) } == .EROFS)
        #expect(driver.calls.isEmpty)
    }
}
