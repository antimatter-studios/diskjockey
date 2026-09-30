//
//  XfsVolumeTests.swift — the REAL XfsVolume, over a stand-in driver.
//
//  WHAT THIS REPLACES
//  ------------------
//  `DiskJockeyTests/XfsVolumeTests.swift` held eleven cases against a mock
//  backend and a set of "drivers mirroring the volume's wiring". None of
//  them loaded XfsVolume, which lived in the appex and made its fs_xfs_*
//  calls inline. The mirror said a failed read threw; the volume answered
//  it with zero bytes, which FSKit reads as the end of the file. The
//  mirror's author wrote down what the volume should do, and nothing
//  checked that it did (diskjockey#196).
//
//  The C calls now live in XfsDriver.swift behind ReadOnlyVolumeDriver,
//  and XfsVolume.swift builds as DiskJockeyXFSCore. Every case here calls
//  the production method. Expected values come from FSKit's contract, from
//  fs_xfs.h, or from what a read-only volume means — never from the body
//  under test.
//
//  Host-free: no app, no extension bundle, no Rust, no C, nothing launched.
//

import Foundation
import FSKit
import Testing
@testable import DiskJockeyXFSCore
@testable import DiskJockeyLibrary

// MARK: - A driver that answers from a table

/// A read-only tree held in memory, answering the way fs_xfs.h says the
/// real driver does: nil / negative / a walk verdict on failure, with the
/// reason left in `lastErrno()`.
private final class TableDriver: ReadOnlyVolumeDriver {

    struct Node {
        var attr: ReadOnlyFileAttributes
        var data: [UInt8] = []
        var target: [UInt8]? = nil
    }

    var nodes: [VolumePath: Node] = [:]
    var errno: Int32 = 0

    /// Paths whose stat fails with this errno instead of answering.
    var statFailures: [VolumePath: Int32] = [:]
    /// Paths whose read fails with this errno.
    var readFailures: [VolumePath: Int32] = [:]
    /// Directories whose walk fails after this many entries.
    var walkFailsAfter: [VolumePath: Int] = [:]
    var info: ReadOnlyVolumeInfo? = nil

    /// Every path the volume handed to `stat`, in order.
    private(set) var statted: [VolumePath] = []
    private(set) var unmounts = 0

    func volumeInfo() -> ReadOnlyVolumeInfo? { info }

    func stat(_ path: VolumePath) -> ReadOnlyFileAttributes? {
        statted.append(path)
        if let e = statFailures[path] { errno = e; return nil }
        guard let n = nodes[path] else { errno = ENOENT; return nil }
        return n.attr
    }

    /// The direct children of `path`, in byte order.
    func children(of path: VolumePath) -> [VolumePath] {
        let prefix = path == .root ? path.bytes : path.bytes + [UInt8(ascii: "/")]
        return nodes.keys
            .filter { key in
                key != path && key.bytes.starts(with: prefix)
                    && !key.bytes.dropFirst(prefix.count).contains(UInt8(ascii: "/"))
            }
            .sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
    }

    func walkDirectory(_ path: VolumePath,
                       _ visit: (ReadOnlyDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk {
        guard let dir = nodes[path], dir.attr.fileType == .directory else {
            errno = ENOTDIR
            return .openFailed
        }
        for (i, child) in children(of: path).enumerated() {
            if let limit = walkFailsAfter[path], i == limit {
                errno = EIO
                return .failedPartway
            }
            let n = nodes[child]!
            if !visit(ReadOnlyDirectoryEntry(name: child.lastComponent, inode: n.attr.inode,
                                             fileType: n.attr.fileType)) {
                return .finished
            }
        }
        return .finished
    }

    func read(_ path: VolumePath, at offset: UInt64,
              into buffer: UnsafeMutableRawBufferPointer) -> Int64 {
        if let e = readFailures[path] { errno = e; return -1 }
        guard let n = nodes[path] else { errno = ENOENT; return -1 }
        guard n.attr.fileType == .file else { errno = EISDIR; return -1 }
        let start = min(Int(offset), n.data.count)
        let count = min(buffer.count, n.data.count - start)
        for i in 0..<count { buffer[i] = n.data[start + i] }
        return Int64(count)
    }

    func readlink(_ path: VolumePath, _ buffer: UnsafeMutablePointer<CChar>,
                  _ size: Int) -> Int32 {
        guard let target = nodes[path]?.target else { errno = EINVAL; return -1 }
        guard target.count + 1 <= size else { errno = ERANGE; return -1 }
        for (i, b) in target.enumerated() { buffer[i] = CChar(bitPattern: b) }
        buffer[target.count] = 0
        return Int32(target.count)
    }

    func lastErrno() -> Int32 { errno }

    func unmount() { unmounts += 1 }
}

private func attr(_ inode: UInt64, _ type: ReadOnlyFileType,
                  mode: UInt32 = 0o644, size: UInt64 = 0) -> ReadOnlyFileAttributes {
    ReadOnlyFileAttributes(inode: inode, mode: mode, uid: 501, gid: 20, size: size,
                           linkCount: 1, mtime: 1_700_000_000, fileType: type)
}

/// An XFS inode number past 32 bits: the allocation group lives in the
/// high bits, so a truncation would name a different inode.
private let wideInode: UInt64 = 0x1_0000_0084

private func seededDriver() -> TableDriver {
    let d = TableDriver()
    d.nodes["/"] = .init(attr: attr(128, .directory, mode: 0o755))
    d.nodes["/dir"] = .init(attr: attr(131, .directory, mode: 0o755))
    d.nodes["/dir/file.txt"] = .init(attr: attr(wideInode, .file, size: 12),
                                     data: Array("xfs contents".utf8))
    d.nodes["/link"] = .init(attr: attr(133, .symlink, mode: 0o777),
                             target: Array("dir/file.txt".utf8))
    return d
}

private func makeVolume(_ driver: TableDriver) -> XfsVolume {
    XfsVolume(volumeID: FSVolume.Identifier(uuid: UUID()),
              volumeName: FSFileName(string: "test"),
              driver: driver,
              contextPtr: nil,
              bsdName: "disk0s1",
              stats: IOStatsCollector(label: "test", emit: { _ in }))
}

private func posixCode(_ body: () async throws -> Void) async -> POSIXErrorCode? {
    do { try await body(); return nil }
    catch let e as POSIXError { return e.code }
    catch { return nil }
}

private func read(_ volume: XfsVolume, _ item: FSItem,
                  at offset: off_t, length: Int) throws -> [UInt8] {
    var out = [UInt8](repeating: 0xAA, count: length)
    let n = try out.withUnsafeMutableBytes {
        try volume.readBytes(from: item, at: offset, into: $0)
    }
    return Array(out.prefix(n))
}

private func list(_ volume: XfsVolume, _ dir: XfsItem, after cookie: UInt64 = 0,
                  room: Int = .max, withAttributes: Bool = false)
    throws -> (entries: [PackableDirectoryEntry], end: UInt64) {
    var packed: [PackableDirectoryEntry] = []
    let end = try volume.entries(of: dir, after: cookie, withAttributes: withAttributes) {
        guard packed.count < room else { return false }
        packed.append($0)
        return true
    }
    return (packed, end)
}

// MARK: - Tests

@Suite("XfsVolume")
struct XfsVolumeTests {

    // MARK: what the volume declares

    /// The defect this style of test could not see when it was a mirror:
    /// XFS is journalled, and the volume once said otherwise.
    @Test func declaresAJournalButNeverAnActiveOne() {
        let caps = makeVolume(seededDriver()).supportedVolumeCapabilities
        #expect(caps.supportsJournal)
        #expect(!caps.supportsActiveJournal)
        #expect(caps.supports64BitObjectIDs)
        #expect(caps.supportsSymbolicLinks)
        #expect(!caps.supportsHardLinks)
        #expect(caps.caseFormat == .sensitive)
    }

    @Test func pathConfIsXfsAndReadOnly() {
        let v = makeVolume(seededDriver())
        #expect(v.maximumNameLength == 255)
        #expect(v.restrictsOwnershipChanges)
        #expect(!v.truncatesLongNames)
    }

    @Test func statfsPassesTheDriversBlocksThroughAsXfs() {
        let d = seededDriver()
        d.info = ReadOnlyVolumeInfo(capacity: .blocks(blockSize: 4096, total: 1000, free: 0),
                                    ioSize: 4096, totalInodes: 64)
        let s = makeVolume(d).volumeStatistics
        #expect(s.fileSystemTypeName == "xfs")
        #expect(s.blockSize == 4096)
        #expect(s.totalBlocks == 1000)
        #expect(s.availableBlocks == 0)
        #expect(s.totalFiles == 64)
    }

    @Test func statfsWithoutDriverFiguresIsStillXfs() {
        #expect(makeVolume(seededDriver()).volumeStatistics.fileSystemTypeName == "xfs")
    }

    // MARK: lifecycle

    @Test func activateAnswersTheRootByItsOwnInode() throws {
        let item = try makeVolume(seededDriver()).rootItem()
        #expect(item.inode == 128)
        #expect(item.path == "/")
        #expect(item.parentInode == nil)
    }

    /// A root that cannot be read is a mount that failed. Inventing an
    /// inode number for it hands FSKit an item that names nothing.
    @Test func activateRefusesARootItCannotStat() {
        let d = seededDriver()
        d.statFailures["/"] = EIO
        #expect(throws: POSIXError(.EIO)) { _ = try makeVolume(d).rootItem() }
    }

    @Test func deactivateUnmountsOnceAndLeavesNothingToCall() async throws {
        let d = seededDriver()
        let v = makeVolume(d)
        try await v.deactivate(options: [])
        await v.unmount()
        #expect(d.unmounts == 1)
        let root = v.item(forInode: 128, path: "/", parentInode: nil)
        let code = await posixCode { _ = try await v.attributes(FSItem.GetAttributesRequest(), of: root) }
        #expect(code == .EBADF)
    }

    // MARK: lookup and attributes

    @Test func lookupKeepsTheFull64BitInode() async throws {
        let v = makeVolume(seededDriver())
        let dir = v.item(forInode: 131, path: "/dir", parentInode: 128)
        let (found, name) = try await v.lookupItem(named: FSFileName(string: "file.txt"),
                                                   inDirectory: dir)
        let item = try #require(found as? XfsItem)
        #expect(item.inode == wideInode)
        #expect(item.path == "/dir/file.txt")
        #expect(item.parentInode == 131)
        #expect(name.string == "file.txt")
    }

    @Test func lookupOfTheSameChildTwiceIsOneItem() async throws {
        let v = makeVolume(seededDriver())
        let dir = v.item(forInode: 131, path: "/dir", parentInode: 128)
        let a = try await v.lookupItem(named: FSFileName(string: "file.txt"), inDirectory: dir).0
        let b = try await v.lookupItem(named: FSFileName(string: "file.txt"), inDirectory: dir).0
        #expect(a === b)
    }

    @Test func lookupOfAMissingChildIsENOENT() async {
        let v = makeVolume(seededDriver())
        let dir = v.item(forInode: 131, path: "/dir", parentInode: 128)
        let code = await posixCode {
            _ = try await v.lookupItem(named: FSFileName(string: "absent"), inDirectory: dir)
        }
        #expect(code == .ENOENT)
    }

    /// ENOENT tells Finder the file is gone. A driver that could not read
    /// the inode has not said that, and the volume must not say it for it.
    @Test func lookupThatFailsForAnotherReasonReportsThatReason() async {
        let d = seededDriver()
        d.statFailures["/dir/file.txt"] = EIO
        let v = makeVolume(d)
        let dir = v.item(forInode: 131, path: "/dir", parentInode: 128)
        let code = await posixCode {
            _ = try await v.lookupItem(named: FSFileName(string: "file.txt"), inDirectory: dir)
        }
        #expect(code == .EIO)
    }

    @Test func attributesCarryTheItemsParentAndTheDriversFields() async throws {
        let v = makeVolume(seededDriver())
        let file = v.item(forInode: wideInode, path: "/dir/file.txt", parentInode: 131)
        let a = try await v.attributes(FSItem.GetAttributesRequest(), of: file)
        #expect(a.fileID.rawValue == wideInode)
        #expect(a.parentID.rawValue == 131)
        #expect(a.type == .file)
        #expect(a.size == 12)
        #expect(a.mode == 0o644)
    }

    @Test func attributesThatCannotBeReadReportTheDriversReason() async {
        let d = seededDriver()
        d.statFailures["/dir/file.txt"] = EIO
        let v = makeVolume(d)
        let file = v.item(forInode: wideInode, path: "/dir/file.txt", parentInode: 131)
        let code = await posixCode { _ = try await v.attributes(FSItem.GetAttributesRequest(), of: file) }
        #expect(code == .EIO)
    }

    // MARK: reading

    @Test func readReturnsTheFilesBytes() throws {
        let v = makeVolume(seededDriver())
        let file = v.item(forInode: wideInode, path: "/dir/file.txt", parentInode: 131)
        #expect(try read(v, file, at: 0, length: 64) == Array("xfs contents".utf8))
        #expect(try read(v, file, at: 4, length: 8) == Array("contents".utf8))
        #expect(try read(v, file, at: 12, length: 8) == [])
    }

    /// THE DEFECT THE MIRROR HID. fs_xfs_read_file returns -1 on failure.
    /// Reported as zero bytes, a read error is the end of the file: the
    /// copy is silently short, and nothing tells the user.
    @Test func aFailedReadThrowsTheDriversErrnoRatherThanEndingTheFile() {
        let d = seededDriver()
        d.readFailures["/dir/file.txt"] = EIO
        let v = makeVolume(d)
        let file = v.item(forInode: wideInode, path: "/dir/file.txt", parentInode: 131)
        #expect(throws: POSIXError(.EIO)) { _ = try read(v, file, at: 0, length: 64) }
    }

    @Test func readingADirectoryIsRefused() {
        let v = makeVolume(seededDriver())
        let dir = v.item(forInode: 131, path: "/dir", parentInode: 128)
        #expect(throws: POSIXError(.EISDIR)) { _ = try read(v, dir, at: 0, length: 8) }
    }

    // MARK: enumeration

    @Test func listingARootNamesOnlyItsOwnChildrenWithRisingCookies() throws {
        let v = makeVolume(seededDriver())
        let root = v.item(forInode: 128, path: "/", parentInode: nil)
        let (entries, end) = try list(v, root)
        #expect(entries.map { $0.name.string } == ["dir", "link"])
        #expect(entries.map { $0.itemType } == [.directory, .symlink])
        #expect(entries.map { $0.itemID.rawValue } == [131, 133])
        #expect(entries.map { $0.nextCookie.rawValue } == [1, 2])
        #expect(end == 3)
    }

    @Test func listingResumesAfterTheCookieItWasGiven() throws {
        let v = makeVolume(seededDriver())
        let root = v.item(forInode: 128, path: "/", parentInode: nil)
        let (entries, _) = try list(v, root, after: 1)
        #expect(entries.map { $0.name.string } == ["link"])
    }

    /// A full packer stops the walk, and the cookie returned is the one
    /// the next call must resume from — so nothing is skipped or repeated.
    @Test func aFullPackerStopsAtAnEntryTheNextCallReturns() throws {
        let v = makeVolume(seededDriver())
        let root = v.item(forInode: 128, path: "/", parentInode: nil)
        let first = try list(v, root, room: 1)
        #expect(first.entries.map { $0.name.string } == ["dir"])
        let second = try list(v, root, after: first.entries.last!.nextCookie.rawValue)
        #expect(second.entries.map { $0.name.string } == ["link"])
    }

    @Test func listingWithAttributesGivesEachChildItsDirectoryAsParent() throws {
        let v = makeVolume(seededDriver())
        let dir = v.item(forInode: 131, path: "/dir", parentInode: 128)
        let (entries, _) = try list(v, dir, withAttributes: true)
        let a = try #require(entries.first?.attributes)
        #expect(a.fileID.rawValue == wideInode)
        #expect(a.parentID.rawValue == 131)
    }

    @Test func listingSomethingThatIsNotADirectoryFails() {
        let v = makeVolume(seededDriver())
        let file = v.item(forInode: wideInode, path: "/dir/file.txt", parentInode: 131)
        #expect(throws: POSIXError.self) { _ = try list(v, file) }
    }

    /// A walk the driver reports as stopped partway is a failed listing,
    /// not a short one: read as the end, the directory silently loses the
    /// rest of its entries. fs_xfs_dir_open reads a directory whole, so
    /// the C driver stops partway only on a name it cannot hand back; this
    /// pins the volume's half of ReadOnlyDirectoryWalk.
    @Test func aWalkThatFailsPartwayThrowsRatherThanEndingTheListing() {
        let d = seededDriver()
        d.walkFailsAfter["/"] = 1
        let v = makeVolume(d)
        let root = v.item(forInode: 128, path: "/", parentInode: nil)
        #expect(throws: POSIXError(.EIO)) { _ = try list(v, root) }
    }

    // MARK: names that are not UTF-8 (diskjockey#219)

    /// caf\xE9.txt: Latin-1, not UTF-8. A String would repair the \xE9 to
    /// U+FFFD and show — and look up — a different name.
    private static let latin1Name: [UInt8] = Array("caf".utf8) + [0xE9] + Array(".txt".utf8)

    private func driverWithLatin1Child() -> TableDriver {
        let d = seededDriver()
        d.nodes[VolumePath(bytes: Array("/dir/".utf8) + Self.latin1Name)] =
            .init(attr: attr(140, .file, size: 1), data: [0x41])
        return d
    }

    @Test func aNameThatIsNotUTF8IsListedByItsOwnBytes() throws {
        let v = makeVolume(driverWithLatin1Child())
        let dir = v.item(forInode: 131, path: "/dir", parentInode: 128)
        let (entries, _) = try list(v, dir)
        #expect(entries.map { [UInt8]($0.name.data) }
                == [Self.latin1Name, Array("file.txt".utf8)])
    }

    /// am-fs-xfs 0.9.0 takes a path byte for byte, so the entry's own bytes
    /// are handed to the driver: it is statted, and carries attributes.
    @Test func aNameThatIsNotUTF8IsStattedByItsOwnBytes() throws {
        let d = driverWithLatin1Child()
        let v = makeVolume(d)
        let dir = v.item(forInode: 131, path: "/dir", parentInode: 128)
        let (entries, _) = try list(v, dir, withAttributes: true)
        #expect(entries.first?.attributes?.fileID.rawValue == 140)
        #expect(entries.last?.attributes != nil)
        #expect(d.statted.contains(VolumePath(bytes: Array("/dir/".utf8) + Self.latin1Name)))
    }

    @Test func lookingUpANameThatIsNotUTF8ReachesTheDriverByItsOwnBytes() async throws {
        let d = driverWithLatin1Child()
        let v = makeVolume(d)
        let dir = v.item(forInode: 131, path: "/dir", parentInode: 128)
        let (found, name) = try await v.lookupItem(named: FSFileName(data: Data(Self.latin1Name)),
                                                   inDirectory: dir)
        let item = try #require(found as? XfsItem)
        #expect(item.inode == 140)
        #expect(item.volumePath == VolumePath(bytes: Array("/dir/".utf8) + Self.latin1Name))
        #expect([UInt8](name.data) == Self.latin1Name)
        #expect(d.statted == [VolumePath(bytes: Array("/dir/".utf8) + Self.latin1Name)])
    }

    /// A target is a path, and a path is bytes.
    @Test func aSymlinkTargetThatIsNotUTF8IsReturnedByItsBytes() async throws {
        let d = seededDriver()
        d.nodes["/link"]?.target = Self.latin1Name
        let v = makeVolume(d)
        let link = v.item(forInode: 133, path: "/link", parentInode: 128)
        #expect([UInt8](try await v.readSymbolicLink(link).data) == Self.latin1Name)
    }

    // MARK: symbolic links

    @Test func readlinkReturnsTheTarget() async throws {
        let v = makeVolume(seededDriver())
        let link = v.item(forInode: 133, path: "/link", parentInode: 128)
        #expect(try await v.readSymbolicLink(link).string == "dir/file.txt")
    }

    @Test func readlinkOfAFileReportsTheDriversErrno() async {
        let v = makeVolume(seededDriver())
        let file = v.item(forInode: wideInode, path: "/dir/file.txt", parentInode: 131)
        let code = await posixCode { _ = try await v.readSymbolicLink(file) }
        #expect(code == .EINVAL)
    }

    // MARK: the read-only contract

    /// Each mutating operation, called on the real volume. EROFS is the
    /// errno for a read-only filesystem, not the filesystem of that name.
    @Test func everyMutatingOperationIsRefusedWithEROFS() async {
        let d = seededDriver()
        let v = makeVolume(d)
        let root = v.item(forInode: 128, path: "/", parentInode: nil)
        let file = v.item(forInode: wideInode, path: "/dir/file.txt", parentInode: 131)
        let name = FSFileName(string: "new")
        let set = FSItem.SetAttributesRequest()

        let codes: [POSIXErrorCode?] = [
            await posixCode { _ = try await v.setAttributes(set, on: file) },
            await posixCode { _ = try await v.createItem(named: name, type: .file,
                                                         inDirectory: root, attributes: set) },
            await posixCode { _ = try await v.createSymbolicLink(named: name, inDirectory: root,
                                                                 attributes: set, linkContents: name) },
            await posixCode { _ = try await v.createLink(to: file, named: name, inDirectory: root) },
            await posixCode { try await v.removeItem(file, named: name, fromDirectory: root) },
            await posixCode { _ = try await v.renameItem(file, inDirectory: root,
                                                         named: FSFileName(string: "file.txt"),
                                                         to: name, inDirectory: root, overItem: nil) },
            await posixCode { _ = try await v.write(contents: Data("x".utf8), to: file, at: 0) },
        ]
        #expect(codes == Array(repeating: .EROFS, count: 7))
        // Refused before reaching the driver: the file is untouched.
        #expect(d.nodes["/dir/file.txt"]?.data == Array("xfs contents".utf8))
    }
}
