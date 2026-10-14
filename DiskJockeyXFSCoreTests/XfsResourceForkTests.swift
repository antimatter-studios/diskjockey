//
//  XfsResourceForkTests.swift — a file's resource fork on XFS, kept in the
//  AppleDouble `._` file beside it (diskjockey#353).
//
//  macOS hands a resource fork over as the extended attribute
//  `com.apple.ResourceFork`, and XFS caps an attribute value at 64 KiB
//  (XATTR_SIZE_MAX): rust-fs-xfs refuses a larger one with E2BIG, so a file
//  whose fork is larger could not be copied onto the volume. The kernel's
//  own answer for a volume that cannot keep an attribute is the AppleDouble
//  file: when a volume answers an extended attribute request with ENOTSUP,
//  xnu's vn_setxattr, vn_getxattr and vn_removexattr store, read and remove
//  it in `._<name>` beside the file, the way msdos, exFAT and NFS volumes
//  keep every attribute. Samba's `fruit:resource = file` and netatalk keep
//  a resource fork on a Linux filesystem the same way, for the same limit.
//
//  Measured on this macOS 26.4 host, on an FSKit msdos volume (an
//  hdiutil-made FAT32 image), 2026-10-14: setxattr of a 102,400-byte
//  resource fork succeeds and writes a 106,210-byte `._f` whose 50-byte
//  header names Finder info at 0x32 for 0xEB0 bytes and the resource fork at
//  0xEE2 for 0x19000; removexattr leaves the entry with length 0; a rename
//  moves `._f` with its file and an unlink removes it. That header is the
//  fixture below.
//
//  These tests hold the volume to:
//
//  - every resource fork, of any size, left to the AppleDouble file: set,
//    get and remove answer ENOTSUP and the driver stores nothing, so a fork
//    is never in two places;
//  - the list naming the fork the AppleDouble file holds, since the kernel
//    adds the AppleDouble names to a list only when the volume refuses the
//    whole list, and a fork the list leaves out is not copied off the
//    volume;
//  - a `._` file created and written like any other, so the kernel can
//    write one;
//  - the `._` file removed and renamed with its file, as xnu does for a
//    volume without native attributes, so no fork outlives its file or is
//    left behind by a rename;
//  - every other attribute still native, and one over XFS's limit refused
//    with the driver's E2BIG.
//

import Foundation
import FSKit
import Testing
@testable import DiskJockeyXFSCore
import DiskJockeyLibrary

private let forkName = "com.apple.ResourceFork"
private let rootPath = VolumePath.root
private let filePath = VolumePath(bytes: Array("/f".utf8))
private let appleDoublePath = VolumePath(bytes: Array("/._f".utf8))

/// A driver that keeps files and their attributes in memory, and refuses an
/// attribute value over XFS's 64 KiB with E2BIG as rust-fs-xfs does.
private final class ForkDriver: XfsMountedVolumeDriver {
    var isWritable = true
    var errno: Int32 = 0
    var files: [VolumePath: [UInt8]] = [filePath: Array("data".utf8)]
    var directories: Set<VolumePath> = [rootPath]
    /// The errno `stat` fails with for a path, in place of an answer.
    var statErrno: [VolumePath: Int32] = [:]
    /// The extended attributes of every file, by their XFS name.
    var xattrs: [VolumePath: [String: [UInt8]]] = [filePath: ["user.kept": Array("v".utf8)]]
    private(set) var xattrCalls: [String] = []
    private(set) var stats: [VolumePath] = []
    private var nextInode: UInt64 = 200

    func stat(_ path: VolumePath) -> ReadOnlyFileAttributes? {
        stats.append(path)
        if let failure = statErrno[path] { errno = failure; return nil }
        if directories.contains(path) {
            return ReadOnlyFileAttributes(inode: 64, mode: 0o040755, uid: 0, gid: 0, size: 6,
                                          linkCount: 2, mtime: 0, fileType: .directory)
        }
        guard let bytes = files[path] else { errno = ENOENT; return nil }
        return ReadOnlyFileAttributes(inode: 128, mode: 0o100644, uid: 0, gid: 0,
                                      size: UInt64(bytes.count), linkCount: 1,
                                      mtime: 0, fileType: .file)
    }

    func read(_ path: VolumePath, at offset: UInt64,
              into buffer: UnsafeMutableRawBufferPointer) -> Int64 {
        guard let bytes = files[path] else { errno = ENOENT; return -1 }
        guard offset < UInt64(bytes.count) else { return 0 }
        let slice = bytes[Int(offset)..<min(bytes.count, Int(offset) + buffer.count)]
        buffer.copyBytes(from: slice)
        return Int64(slice.count)
    }

    func write(_ path: VolumePath, at offset: UInt64,
               from buffer: UnsafeRawBufferPointer) -> Int64 {
        guard var bytes = files[path] else { errno = ENOENT; return -1 }
        let end = Int(offset) + buffer.count
        if end > bytes.count {
            bytes.append(contentsOf: [UInt8](repeating: 0, count: end - bytes.count))
        }
        bytes.replaceSubrange(Int(offset)..<end, with: buffer)
        files[path] = bytes
        return Int64(buffer.count)
    }

    func create(_ path: VolumePath, mode: UInt16) -> UInt64 {
        guard files[path] == nil else { errno = EEXIST; return 0 }
        files[path] = []
        nextInode += 1
        return nextInode
    }

    func getXattr(_ path: VolumePath, name: [UInt8]) -> [UInt8]? {
        guard let v = xattrs[path]?[String(decoding: name, as: UTF8.self)] else {
            errno = ENOATTR
            return nil
        }
        return v
    }

    func listXattrs(_ path: VolumePath) -> [[UInt8]]? {
        (xattrs[path] ?? [:]).keys.sorted().map { Array($0.utf8) }
    }

    func setXattr(_ path: VolumePath, name: [UInt8], value: [UInt8], flags: Int32) -> Int32 {
        let key = String(decoding: name, as: UTF8.self)
        xattrCalls.append("set \(key) \(value.count)")
        guard value.count <= 65_536 else { errno = E2BIG; return -1 }
        xattrs[path, default: [:]][key] = value
        return 0
    }

    func removeXattr(_ path: VolumePath, name: [UInt8]) -> Int32 {
        let key = String(decoding: name, as: UTF8.self)
        xattrCalls.append("remove \(key)")
        guard xattrs[path]?.removeValue(forKey: key) != nil else { errno = ENOATTR; return -1 }
        return 0
    }

    func volumeInfo() -> ReadOnlyVolumeInfo? { nil }
    func walkDirectory(_ path: VolumePath,
                       _ visit: (ReadOnlyDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk { .finished }
    func truncate(_ path: VolumePath, to size: UInt64, modified: timespec?) -> Int32 { 0 }
    func setAttributes(_ path: VolumePath, mode: UInt32?, uid: UInt32?, gid: UInt32?,
                       accessed: timespec?, modified: timespec?) -> Int32 { 0 }
    func flush() -> Int32 { 0 }
    func mkdir(_ path: VolumePath, mode: UInt16) -> UInt64 { errno = ENOTSUP; return 0 }

    /// The errno `unlink` fails with for a path, in place of removing it.
    var unlinkErrno: [VolumePath: Int32] = [:]
    private(set) var namespaceCalls: [String] = []

    func unlink(_ path: VolumePath) -> Int32 {
        namespaceCalls.append("unlink \(String(decoding: path.bytes, as: UTF8.self))")
        if let failure = unlinkErrno[path] { errno = failure; return -1 }
        guard files.removeValue(forKey: path) != nil else { errno = ENOENT; return -1 }
        xattrs[path] = nil
        return 0
    }

    func rmdir(_ path: VolumePath) -> Int32 {
        namespaceCalls.append("rmdir \(String(decoding: path.bytes, as: UTF8.self))")
        guard directories.remove(path) != nil else { errno = ENOENT; return -1 }
        return 0
    }

    func link(_ source: VolumePath, to destination: VolumePath) -> Int32 { errno = ENOTSUP; return -1 }

    func rename(_ source: VolumePath, to destination: VolumePath, replace: Bool) -> Int32 {
        namespaceCalls.append("rename \(String(decoding: source.bytes, as: UTF8.self))"
                              + " \(String(decoding: destination.bytes, as: UTF8.self))")
        guard let bytes = files.removeValue(forKey: source) else { errno = ENOENT; return -1 }
        files[destination] = bytes
        xattrs[destination] = xattrs.removeValue(forKey: source)
        return 0
    }
    func readlink(_ path: VolumePath, _ buffer: UnsafeMutablePointer<CChar>, _ size: Int) -> Int32 { -1 }
    func lastErrno() -> Int32 { errno }
    func unmount() { isWritable = false }
}

private func be32(_ v: UInt32) -> [UInt8] {
    [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
}

/// The AppleDouble file macOS's kernel writes beside a file given a
/// resource fork, laid out as measured (see the header comment): magic
/// 0x00051607, version 0x00020000, "Mac OS X" padded to 16 bytes, two
/// entries — Finder info (9) at 0x32 for 0xEB0 bytes, the resource fork (2)
/// at 0xEE2 to the end of the file. The Finder info area is left zero; the
/// kernel keeps its own attribute header there, which nothing here reads.
private func appleDouble(fork: [UInt8]) -> [UInt8] {
    var header: [UInt8] = be32(0x0005_1607) + be32(0x0002_0000)
    header += Array("Mac OS X        ".utf8)
    header += [0x00, 0x02]
    header += be32(9) + be32(0x32) + be32(0xEB0)
    header += be32(2) + be32(0xEE2) + be32(UInt32(fork.count))
    return header + [UInt8](repeating: 0, count: 0xEE2 - header.count) + fork
}

/// 100 KiB, over XFS's 64 KiB attribute limit, in a pattern a misplaced
/// byte shows up in.
private let bigFork: [UInt8] = (0..<102_400).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }

/// Files called `._f` that hold no fork the kernel would return.
private let notAppleDouble: [(String, [UInt8])] = {
    let real = appleDouble(fork: bigFork)
    let version1: [UInt8] = Array(real[0..<4]) + be32(0x0001_0000) + Array(real[8...])
    return [
        ("not AppleDouble", Array("just a file called ._f".utf8)),
        ("version 1", version1),
        ("fork past the end", Array(real.dropLast())),
        ("header cut short", Array(real.prefix(40))),
    ]
}()

private func fixture(writable: Bool = true) throws -> (XfsVolume, ForkDriver, XfsItem) {
    let driver = ForkDriver()
    let access = writable
        ? try XfsMountPolicy.readWrite.authorize(deviceIsWritable: true, mountedDriver: .success(true))
        : .readOnly
    let volume = XfsVolume(volumeID: FSVolume.Identifier(), volumeName: FSFileName(string: "fork"),
                           driver: driver, contextPtr: nil, bsdName: "fork-test",
                           stats: IOStatsCollector(label: "fork-test", emit: { _ in }),
                           mountAccess: access)
    return (volume, driver, volume.item(forInode: 128, path: filePath, parentInode: 64))
}

private func name(_ s: String) -> FSFileName { FSFileName(string: s) }

private func code(_ body: () async throws -> Void) async -> POSIXErrorCode? {
    do { try await body(); return nil } catch let e as POSIXError { return e.code } catch { return nil }
}

private func listed(_ volume: XfsVolume, _ item: FSItem) async throws -> [String] {
    try await volume.xattrs(of: item).compactMap(\.string).sorted()
}

@Suite("XFS resource forks in the AppleDouble file")
struct XfsResourceForkTests {

    // MARK: - Left to the kernel's AppleDouble file

    /// Whatever its size, so that one fork is never in two places: a small
    /// one stored natively and a large one in `._f` would leave a stale copy
    /// behind whenever a fork changed size across the limit.
    @Test(arguments: [1, 65_536, 102_400])
    func aResourceForkOfAnySizeIsLeftToTheAppleDoubleFile(size: Int) async throws {
        let (volume, driver, item) = try fixture()
        #expect(await code {
            try await volume.setXattr(named: name(forkName), to: Data(bigFork.prefix(size)),
                                      on: item, policy: .alwaysSet)
        } == .ENOTSUP)
        #expect(driver.xattrCalls.isEmpty)
    }

    /// The kernel decides create and replace against the AppleDouble file,
    /// and removes the fork from it.
    @Test(arguments: [FSVolume.SetXattrPolicy.mustCreate, .mustReplace, .delete])
    func everyPolicyOnAResourceForkIsLeftToTheAppleDoubleFile(
        _ policy: FSVolume.SetXattrPolicy
    ) async throws {
        let (volume, driver, item) = try fixture()
        let value: Data? = policy == .delete ? nil : Data([1])
        #expect(await code {
            try await volume.setXattr(named: name(forkName), to: value, on: item, policy: policy)
        } == .ENOTSUP)
        #expect(driver.xattrCalls.isEmpty)
    }

    /// ENOTSUP, not ENOATTR: the kernel reads the AppleDouble file only when
    /// the volume says it does not keep the attribute, and answers ENOATTR
    /// itself when there is no fork there either.
    @Test(arguments: [true, false])
    func readingAResourceForkIsLeftToTheAppleDoubleFile(writable: Bool) async throws {
        let (volume, driver, item) = try fixture(writable: writable)
        driver.files[appleDoublePath] = appleDouble(fork: bigFork)
        #expect(await code { _ = try await volume.xattr(named: name(forkName), of: item) } == .ENOTSUP)
    }

    /// A read-only mount still refuses the change itself, before the kernel
    /// would try to write an AppleDouble file it cannot create.
    @Test func aReadOnlyMountRefusesAResourceForkWithEROFS() async throws {
        let (volume, driver, item) = try fixture(writable: false)
        #expect(await code {
            try await volume.setXattr(named: name(forkName), to: Data(bigFork), on: item, policy: .alwaysSet)
        } == .EROFS)
        #expect(driver.xattrCalls.isEmpty)
    }

    // MARK: - The list

    /// xnu adds the AppleDouble file's names to a list only when the volume
    /// refuses the whole list, which would lose the native ones. The volume
    /// names the fork itself, so copyfile, which copies what the list names,
    /// takes the fork off the volume too.
    @Test func aForkInTheAppleDoubleFileIsListed() async throws {
        let (volume, driver, item) = try fixture()
        #expect(try await listed(volume, item) == ["kept"])
        driver.files[appleDoublePath] = appleDouble(fork: bigFork)
        #expect(try await listed(volume, item) == [forkName, "kept"])
    }

    /// removexattr leaves the fork's entry in place with length 0 (measured),
    /// and a fork of no bytes is no fork: the kernel answers ENOATTR for it.
    @Test func anEmptyForkIsNotListed() async throws {
        let (volume, driver, item) = try fixture()
        driver.files[appleDoublePath] = appleDouble(fork: [])
        #expect(try await listed(volume, item) == ["kept"])
    }

    /// A `._f` that is not an AppleDouble file, or whose entries reach past
    /// its end, holds no fork the kernel would return, so none is listed and
    /// the list itself still succeeds.
    @Test(arguments: notAppleDouble)
    func aSiblingThatIsNotAnAppleDoubleFileListsNoFork(_ label: String, _ bytes: [UInt8]) async throws {
        let (volume, driver, item) = try fixture()
        driver.files[appleDoublePath] = bytes
        #expect(try await listed(volume, item) == ["kept"], "\(label)")
    }

    /// Only the AppleDouble file's fork is the kernel's to return, so a
    /// `user.com.apple.ResourceFork` already stored natively is not named:
    /// a list naming what a get cannot return would be copied as an error.
    @Test func aNativeResourceForkAttributeIsNotListed() async throws {
        let (volume, driver, item) = try fixture()
        driver.xattrs[filePath]?["user.\(forkName)"] = [1, 2, 3]
        #expect(try await listed(volume, item) == ["kept"])
    }

    /// A sibling that cannot be read is not the same as no sibling: a list
    /// that went on without it would leave a fork out of a copy unseen.
    @Test func aSiblingThatCannotBeStatedFailsTheList() async throws {
        let (volume, driver, item) = try fixture()
        driver.statErrno[appleDoublePath] = EIO
        #expect(await code { _ = try await volume.xattrs(of: item) } == .EIO)
    }

    /// `._<name>` in the item's own directory, as the kernel names it.
    @Test func theAppleDoubleFileIsTheItemsSibling() async throws {
        let (volume, driver, _) = try fixture()
        let nested = VolumePath(bytes: Array("/d/f".utf8))
        driver.files[nested] = []
        driver.files[VolumePath(bytes: Array("/d/._f".utf8))] = appleDouble(fork: bigFork)
        let item = volume.item(forInode: 300, path: nested, parentInode: 65)
        #expect(try await listed(volume, item) == [forkName])
    }

    /// The root has no directory to hold a sibling, and is never given one.
    @Test func theRootIsNotGivenASibling() async throws {
        let (volume, driver, _) = try fixture()
        let root = volume.item(forInode: 64, path: rootPath, parentInode: nil)
        #expect(try await listed(volume, root) == [])
        #expect(!driver.stats.contains { $0.bytes.starts(with: Array("/._".utf8)) })
    }

    // MARK: - The copy, end to end

    /// What copyfile and the kernel do to copy a file with a 100 KiB
    /// resource fork onto the volume, in order: the data goes into the file;
    /// setxattr of the fork is answered ENOTSUP, so the kernel creates `._f`
    /// and writes its AppleDouble file; and the copy then reads back as the
    /// source, the fork listed and its bytes in `._f` where the kernel looks
    /// for them.
    @Test func aFileWithA100KiBResourceForkCopiesOntoTheVolume() async throws {
        let (volume, driver, _) = try fixture()
        driver.files[filePath] = nil
        driver.xattrs[filePath] = nil
        let root = volume.item(forInode: 64, path: rootPath, parentInode: nil)
        let attributes = FSItem.SetAttributesRequest()

        let (copy, _) = try await volume.createItem(named: name("f"), type: .file,
                                                    inDirectory: root, attributes: attributes)
        let data = Data("the data fork".utf8)
        #expect(try await volume.write(contents: data, to: copy, at: 0) == data.count)

        let refused = await code {
            try await volume.setXattr(named: name(forkName), to: Data(bigFork), on: copy, policy: .alwaysSet)
        }
        try #require(refused == .ENOTSUP, "the kernel writes an AppleDouble file only after ENOTSUP")

        // The kernel's half: create `._f` and write the AppleDouble file.
        let (sidecar, _) = try await volume.createItem(named: name("._f"), type: .file,
                                                       inDirectory: root, attributes: attributes)
        let written = appleDouble(fork: bigFork)
        #expect(try await volume.write(contents: Data(written), to: sidecar, at: 0) == written.count)

        #expect(driver.files[filePath] == Array(data))
        #expect(try await listed(volume, copy) == [forkName])
        #expect(await code { _ = try await volume.xattr(named: name(forkName), of: copy) } == .ENOTSUP)
        var fork = [UInt8](repeating: 0, count: bigFork.count)
        let n = try fork.withUnsafeMutableBytes {
            try volume.readBytes(from: sidecar, at: 0xEE2, into: $0)
        }
        #expect(n == bigFork.count && fork == bigFork)
        #expect(driver.xattrCalls.isEmpty, "the fork reached no native attribute")
    }

    /// A name of 254 or 255 bytes has no `._` sibling: `._<name>` is longer
    /// than XFS's 255-byte limit, so the kernel can never have made one,
    /// and the list is not failed asking for it.
    @Test func aNameTooLongForASiblingHasNone() async throws {
        let (volume, driver, _) = try fixture()
        let long = VolumePath(bytes: Array("/".utf8) + [UInt8](repeating: UInt8(ascii: "a"), count: 254))
        driver.files[long] = []
        driver.statErrno[VolumePath(bytes: Array("/._".utf8) + Array(long.bytes.dropFirst()))] = ENAMETOOLONG
        let item = volume.item(forInode: 301, path: long, parentInode: 64)
        #expect(try await listed(volume, item) == [])
    }

    // MARK: - The AppleDouble file follows its file

    // xnu moves and removes `._<name>` with its file only on a volume that
    // does not report native extended attributes (kpi_vfs.c, VNOP_REMOVE
    // and vn_rename, under !NATIVE_XATTR); this volume keeps every other
    // attribute natively, so it carries the fork's file along itself.
    // Where the kernel does it too, it finds nothing left to do.

    /// Unlinked with its file, so a later file of the same name does not
    /// inherit the fork.
    @Test func removingAFileRemovesItsAppleDoubleFile() async throws {
        let (volume, driver, item) = try fixture()
        driver.files[appleDoublePath] = appleDouble(fork: bigFork)
        let root = volume.item(forInode: 64, path: rootPath, parentInode: nil)
        try await volume.removeItem(item, named: name("f"), fromDirectory: root)
        #expect(driver.files[filePath] == nil)
        #expect(driver.files[appleDoublePath] == nil)
        #expect(driver.namespaceCalls == ["unlink /f", "unlink /._f"])
    }

    /// A file with no fork beside it removes as before.
    @Test func removingAFileWithNoAppleDoubleFileUnlinksOnlyIt() async throws {
        let (volume, driver, item) = try fixture()
        let root = volume.item(forInode: 64, path: rootPath, parentInode: nil)
        try await volume.removeItem(item, named: name("f"), fromDirectory: root)
        #expect(driver.namespaceCalls == ["unlink /f"])
    }

    /// The file still there keeps its fork: nothing beside it is touched
    /// when the unlink is refused.
    @Test func aRefusedRemovalKeepsTheAppleDoubleFile() async throws {
        let (volume, driver, item) = try fixture()
        driver.files[appleDoublePath] = appleDouble(fork: bigFork)
        driver.unlinkErrno[filePath] = EACCES
        let root = volume.item(forInode: 64, path: rootPath, parentInode: nil)
        #expect(await code {
            try await volume.removeItem(item, named: name("f"), fromDirectory: root)
        } == .EACCES)
        #expect(driver.files[appleDoublePath] != nil)
    }

    /// The kernel's `._` file is a regular file; a directory of that name
    /// is somebody's data and is left alone, as xnu leaves it.
    @Test func aDirectoryNamedLikeTheAppleDoubleFileIsLeftAlone() async throws {
        let (volume, driver, item) = try fixture()
        driver.directories.insert(appleDoublePath)
        let root = volume.item(forInode: 64, path: rootPath, parentInode: nil)
        try await volume.removeItem(item, named: name("f"), fromDirectory: root)
        #expect(driver.directories.contains(appleDoublePath))
        #expect(driver.namespaceCalls == ["unlink /f"])
    }

    /// Removing an AppleDouble file itself touches nothing else.
    @Test func removingTheAppleDoubleFileItselfTouchesNothingElse() async throws {
        let (volume, driver, _) = try fixture()
        driver.files[appleDoublePath] = appleDouble(fork: bigFork)
        let root = volume.item(forInode: 64, path: rootPath, parentInode: nil)
        let sidecar = volume.item(forInode: 129, path: appleDoublePath, parentInode: 64)
        try await volume.removeItem(sidecar, named: name("._f"), fromDirectory: root)
        #expect(driver.files[filePath] != nil)
        #expect(driver.namespaceCalls == ["unlink /._f"])
    }

    /// Renamed with its file, into the destination directory.
    @Test func renamingAFileMovesItsAppleDoubleFile() async throws {
        let (volume, driver, item) = try fixture()
        let fork = appleDouble(fork: bigFork)
        driver.files[appleDoublePath] = fork
        driver.directories.insert(VolumePath(bytes: Array("/d".utf8)))
        let root = volume.item(forInode: 64, path: rootPath, parentInode: nil)
        let dir = volume.item(forInode: 65, path: VolumePath(bytes: Array("/d".utf8)), parentInode: 64)
        _ = try await volume.renameItem(item, inDirectory: root, named: name("f"),
                                        to: name("g"), inDirectory: dir, overItem: nil)
        #expect(driver.files[VolumePath(bytes: Array("/d/g".utf8))] == Array("data".utf8))
        #expect(driver.files[VolumePath(bytes: Array("/d/._g".utf8))] == fork)
        #expect(driver.files[appleDoublePath] == nil)
        #expect(driver.namespaceCalls == ["rename /f /d/g", "rename /._f /d/._g"])
    }

    /// A file renamed over one that had a fork, having none itself, leaves
    /// no stale fork for the name it takes.
    @Test func renamingOverAFileRemovesTheFormerFork() async throws {
        let (volume, driver, item) = try fixture()
        let target = VolumePath(bytes: Array("/g".utf8))
        driver.files[target] = []
        driver.files[VolumePath(bytes: Array("/._g".utf8))] = appleDouble(fork: bigFork)
        let root = volume.item(forInode: 64, path: rootPath, parentInode: nil)
        let over = volume.item(forInode: 130, path: target, parentInode: 64)
        _ = try await volume.renameItem(item, inDirectory: root, named: name("f"),
                                        to: name("g"), inDirectory: root, overItem: over)
        #expect(driver.files[VolumePath(bytes: Array("/._g".utf8))] == nil)
        #expect(driver.namespaceCalls == ["rename /f /g", "unlink /._g"])
    }

    /// Renaming an AppleDouble file itself moves nothing else.
    @Test func renamingTheAppleDoubleFileItselfMovesNothingElse() async throws {
        let (volume, driver, _) = try fixture()
        driver.files[appleDoublePath] = appleDouble(fork: bigFork)
        let root = volume.item(forInode: 64, path: rootPath, parentInode: nil)
        let sidecar = volume.item(forInode: 129, path: appleDoublePath, parentInode: 64)
        _ = try await volume.renameItem(sidecar, inDirectory: root, named: name("._f"),
                                        to: name("._g"), inDirectory: root, overItem: nil)
        #expect(driver.namespaceCalls == ["rename /._f /._g"])
    }

    // MARK: - Every other attribute

    /// Other attributes stay native. One over XFS's limit is refused with
    /// the driver's E2BIG, which says why, as setxattr(2) does on Linux.
    @Test func anotherAttributeOverTheLimitIsTheDriversE2BIG() async throws {
        let (volume, driver, item) = try fixture()
        try await volume.setXattr(named: name("com.example.small"), to: Data([1]), on: item, policy: .alwaysSet)
        #expect(await code {
            try await volume.setXattr(named: name("com.example.big"), to: Data(bigFork),
                                      on: item, policy: .alwaysSet)
        } == .E2BIG)
        #expect(driver.xattrCalls == ["set user.com.example.small 1", "set user.com.example.big 102400"])
    }
}
