//
//  NTFSVolumeTests.swift — the REAL NTFSVolume, over a stand-in backend.
//
//  WHAT THIS REPLACES
//  ------------------
//  `DiskJockeyTests/NTFSVolumeTests.swift` held thirteen cases against a
//  mock backend and a set of "drivers" that reproduced the volume's wiring
//  by hand. None of them loaded NTFSVolume, which lived in the appex and
//  made its fs_ntfs_* calls inline (diskjockey#196). Where the mirror and
//  the volume disagreed, this file pins the volume:
//
//    - a rename over an existing file was mirrored as unlink-then-rename.
//      The volume only renames, with FS_NTFS_RENAME_REPLACE, and leaves the
//      replacement to the driver, which does it atomically: unlinking first
//      lost the original whenever the rename then failed.
//    - a truncate that grows was mirrored as the driver refusing it. The
//      volume refuses it itself, with ENOTSUP, before the driver is asked.
//      (am-fs-ntfs 0.5.0's truncate_h does grow a non-resident file; the
//      volume's refusal predates that and is kept, and pinned, here.)
//
//  The C calls now live in NTFSDriver.swift behind NTFSBackend, and
//  NTFSVolume.swift builds as DiskJockeyNTFSCore. Every case here calls the
//  production method. Expected values come from FSKit's contract, from
//  fs_ntfs.h, from POSIX or from the FILETIME definition — never from the
//  body under test.
//
//  Host-free: no app, no extension bundle, no Rust, no C, nothing launched.
//

import Foundation
import FSKit
import Testing
@testable import DiskJockeyNTFSCore
@testable import DiskJockeyLibrary

// MARK: - A backend that answers from a table and records what it is asked

private final class TableBackend: NTFSBackend {

    enum Call: Equatable {
        case createFile(parent: String, name: String)
        case mkdir(parent: String, name: String)
        case writeContents(String, length: Int)
        case read(String, offset: UInt64, length: Int)
        case truncate(String, size: UInt64)
        case unlink(String)
        case rmdir(String)
        case rename(String, toBasename: String)
        case setTimes(String, NTFSFileTimes)
        case fsck
        case remountThroughDeviceChain
        case unmount
        case releaseDevice
    }

    struct Node {
        var attr: NTFSFileAttributes
        var data: [UInt8] = []
        var target: [UInt8]? = nil
    }

    private(set) var calls: [Call] = []
    var nodes: [VolumePath: Node] = [:]
    var errno: Int32 = 0
    var isMounted = true
    var remountsThroughDeviceChain = false
    var info: NTFSVolumeInfo? = nil
    var fsckResult: Result<NTFSVolume.FsckReport, Error> =
        .success(.init(wasDirty: false, dirtyCleared: false))

    /// Paths whose stat fails with this errno instead of answering.
    var statFailures: [VolumePath: Int32] = [:]
    /// Paths whose read fails with this errno.
    var readFailures: [VolumePath: Int32] = [:]
    /// Directories that cannot be opened, and why.
    var openFailures: [VolumePath: Int32] = [:]
    private var nextRecord: Int64 = 100

    /// Every path the volume handed to `stat`, in order.
    private(set) var statted: [VolumePath] = []

    func lastErrno() -> Int32 { errno }

    func volumeInfo() -> NTFSVolumeInfo? { info }

    func stat(_ path: VolumePath) -> NTFSFileAttributes? {
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

    /// As fs_ntfs_dir_open does: "." and ".." first, then the index.
    func walkDirectory(_ path: VolumePath,
                       _ visit: (NTFSDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk {
        if let e = openFailures[path] { errno = e; return .openFailed }
        guard let dir = nodes[path], dir.attr.fileType == .directory else {
            errno = ENOTDIR
            return .openFailed
        }
        let parent = path == .root ? path
            : VolumePath(bytes: Array(path.bytes[..<path.bytes.lastIndex(of: UInt8(ascii: "/"))!]))
        let parentPath = parent.bytes.isEmpty ? VolumePath.root : parent
        var entries = [
            NTFSDirectoryEntry(name: Array(".".utf8), recordNumber: dir.attr.recordNumber,
                               fileType: .directory),
            NTFSDirectoryEntry(name: Array("..".utf8),
                               recordNumber: nodes[parentPath]!.attr.recordNumber,
                               fileType: .directory),
        ]
        for child in children(of: path) {
            let n = nodes[child]!
            entries.append(NTFSDirectoryEntry(name: child.lastComponent,
                                              recordNumber: n.attr.recordNumber,
                                              fileType: n.attr.fileType))
        }
        for e in entries where !visit(e) { return .finished }
        return .finished
    }

    func read(_ path: VolumePath, at offset: UInt64,
              into buffer: UnsafeMutableRawBufferPointer) -> Int64 {
        calls.append(.read(path.description, offset: offset, length: buffer.count))
        if let e = readFailures[path] { errno = e; return -1 }
        guard let n = nodes[path] else { errno = ENOENT; return -1 }
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

    func writeContents(_ path: VolumePath, _ bytes: UnsafeRawBufferPointer) -> Int64 {
        calls.append(.writeContents(path.description, length: bytes.count))
        guard nodes[path] != nil else { errno = ENOENT; return -1 }
        nodes[path]!.data = Array(bytes)
        nodes[path]!.attr.size = UInt64(bytes.count)
        return Int64(bytes.count)
    }

    func truncate(_ path: VolumePath, to size: UInt64) -> Int64 {
        calls.append(.truncate(path.description, size: size))
        guard nodes[path] != nil else { errno = ENOENT; return -1 }
        nodes[path]!.data = Array(nodes[path]!.data.prefix(Int(size)))
        nodes[path]!.attr.size = size
        return Int64(size)
    }

    private func create(_ type: NTFSFileType, in parent: VolumePath, named name: String) -> Int64 {
        let path = parent.appending(Array(name.utf8))!
        guard nodes[path] == nil else { errno = EEXIST; return -1 }
        let record = nextRecord
        nextRecord += 1
        nodes[path] = Node(attr: attr(UInt64(record), type))
        return record
    }

    func createFile(in parent: VolumePath, named name: String) -> Int64 {
        calls.append(.createFile(parent: parent.description, name: name))
        return create(.file, in: parent, named: name)
    }

    func mkdir(in parent: VolumePath, named name: String) -> Int64 {
        calls.append(.mkdir(parent: parent.description, name: name))
        return create(.directory, in: parent, named: name)
    }

    func unlink(_ path: VolumePath) -> Int32 {
        calls.append(.unlink(path.description))
        nodes[path] = nil
        return 0
    }

    func rmdir(_ path: VolumePath) -> Int32 {
        calls.append(.rmdir(path.description))
        nodes[path] = nil
        return 0
    }

    func rename(_ path: VolumePath, toBasename name: String) -> Int32 {
        calls.append(.rename(path.description, toBasename: name))
        return 0
    }

    func setTimes(_ path: VolumePath, _ times: NTFSFileTimes) -> Int32 {
        calls.append(.setTimes(path.description, times))
        return 0
    }

    func fsck(onProgress: @escaping (String, UInt64, UInt64) -> Void)
        -> Result<NTFSVolume.FsckReport, Error> {
        calls.append(.fsck)
        return fsckResult
    }

    func remountReadWriteThroughDeviceChain() { calls.append(.remountThroughDeviceChain) }
    func unmount() { calls.append(.unmount) }
    func releaseDevice() { calls.append(.releaseDevice) }
}

private func attr(_ record: UInt64, _ type: NTFSFileType, size: UInt64 = 0,
                  fileAttributes: UInt32 = 0) -> NTFSFileAttributes {
    NTFSFileAttributes(recordNumber: record, size: size,
                       accessTime: (1_700_000_001, 1), modifyTime: (1_700_000_002, 2),
                       changeTime: (1_700_000_003, 3), creationTime: (1_600_000_000, 4),
                       mode: type == .directory ? 0o040755 : 0o100644,
                       linkCount: 1, fileType: type, fileAttributes: fileAttributes)
}

/// The root of an NTFS volume is MFT record 5.
private let rootRecord: UInt64 = 5

private func seededBackend() -> TableBackend {
    let b = TableBackend()
    b.nodes["/"] = .init(attr: attr(rootRecord, .directory))
    b.nodes["/sub"] = .init(attr: attr(64, .directory))
    b.nodes["/greeting"] = .init(attr: attr(65, .file, size: 6), data: Array("hello\n".utf8))
    b.nodes["/link"] = .init(attr: attr(66, .symlink), target: Array("greeting".utf8))
    return b
}

private func makeVolume(_ backend: TableBackend,
                        requiresFsckRemount: Bool = false) -> NTFSVolume {
    NTFSVolume(volumeID: FSVolume.Identifier(uuid: UUID()),
               volumeName: FSFileName(string: "test"),
               backend: backend,
               bsdName: "disk0s1",
               requiresFsckRemount: requiresFsckRemount,
               stats: IOStatsCollector(label: "test", emit: { _ in }))
}

/// The errno a thrown error carries, or nil when nothing was thrown. The
/// volume throws FSKit's `fs_errorForPOSIXError`, an NSError in the POSIX
/// domain.
private func errnoOf(_ body: () async throws -> Void) async -> Int32? {
    do { try await body(); return nil }
    catch {
        let e = error as NSError
        return e.domain == NSPOSIXErrorDomain ? Int32(e.code) : -1
    }
}

private func name(_ s: String) -> FSFileName { FSFileName(string: s) }

private func read(_ volume: NTFSVolume, _ item: FSItem,
                  at offset: off_t, length: Int) throws -> [UInt8] {
    var out = [UInt8](repeating: 0xAA, count: length)
    let n = try out.withUnsafeMutableBytes {
        try volume.readBytes(from: item, at: offset, into: $0)
    }
    return Array(out.prefix(n))
}

private func list(_ volume: NTFSVolume, _ dir: NTFSItem, after cookie: UInt64 = 0,
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

@Suite("NTFSVolume")
struct NTFSVolumeTests {

    private func root(_ v: NTFSVolume) -> NTFSItem {
        v.item(forRecordNumber: rootRecord, path: "/", parentRecordNumber: nil)
    }

    // MARK: what the volume declares

    @Test func declaresAnActiveJournalHardLinksAndCaseInsensitiveNames() {
        let caps = makeVolume(seededBackend()).supportedVolumeCapabilities
        #expect(caps.supportsJournal)
        #expect(caps.supportsActiveJournal)
        #expect(caps.supportsHardLinks)
        #expect(caps.supportsSymbolicLinks)
        #expect(caps.supports64BitObjectIDs)
        #expect(caps.caseFormat == .insensitiveCasePreserving)
    }

    /// NTFS names are UTF-16 on disk and am-fs-ntfs decodes paths as
    /// UTF-8, so the volume must never hand it anything else (diskjockey#219).
    @Test func readsPathsAsUTF8() {
        #expect(NTFSVolume.pathEncoding == .utf8)
    }

    @Test func statfsReportsClustersAsBlocks() {
        let b = seededBackend()
        b.info = NTFSVolumeInfo(clusterSize: 4096, totalClusters: 2560)
        let s = makeVolume(b).volumeStatistics
        #expect(s.blockSize == 4096)
        #expect(s.ioSize == 4096)
        #expect(s.totalBlocks == 2560)
    }

    // MARK: creating (mirror: parent path + basename)

    @Test func creatingAFileAsksForItByParentAndBasename() async throws {
        let b = seededBackend()
        let v = makeVolume(b)
        let (item, _) = try await v.createItem(named: name("foo.txt"), type: .file,
                                               inDirectory: root(v),
                                               attributes: FSItem.SetAttributesRequest())
        #expect(b.calls == [.createFile(parent: "/", name: "foo.txt")])
        let created = try #require(item as? NTFSItem)
        #expect(created.path == "/foo.txt")
        #expect(created.fileRecordNumber == 100)
        #expect(created.parentRecordNumber == rootRecord)
    }

    @Test func creatingAFileInASubdirectoryNamesThatDirectory() async throws {
        let b = seededBackend()
        let v = makeVolume(b)
        let sub = v.item(forRecordNumber: 64, path: "/sub", parentRecordNumber: rootRecord)
        let (item, _) = try await v.createItem(named: name("bar"), type: .file,
                                               inDirectory: sub,
                                               attributes: FSItem.SetAttributesRequest())
        #expect(b.calls == [.createFile(parent: "/sub", name: "bar")])
        #expect((item as? NTFSItem)?.path == "/sub/bar")
        #expect((item as? NTFSItem)?.parentRecordNumber == 64)
    }

    @Test func creatingADirectoryIsAMkdirByParentAndBasename() async throws {
        let b = seededBackend()
        let v = makeVolume(b)
        let (item, _) = try await v.createItem(named: name("newdir"), type: .directory,
                                               inDirectory: root(v),
                                               attributes: FSItem.SetAttributesRequest())
        #expect(b.calls == [.mkdir(parent: "/", name: "newdir")])
        #expect((item as? NTFSItem)?.fileRecordNumber == 100)
    }

    @Test func aFailedCreateReportsTheDriversErrno() async {
        let b = seededBackend()
        let v = makeVolume(b)
        let code = await errnoOf {
            _ = try await v.createItem(named: name("greeting"), type: .file,
                                       inDirectory: root(v),
                                       attributes: FSItem.SetAttributesRequest())
        }
        #expect(code == EEXIST)
    }

    /// There is no handle-based symlink or hard-link call in fs_ntfs.h.
    @Test func symbolicAndHardLinksAreNotSupported() async {
        let b = seededBackend()
        let v = makeVolume(b)
        let greeting = v.item(forRecordNumber: 65, path: "/greeting", parentRecordNumber: rootRecord)
        #expect(await errnoOf {
            _ = try await v.createSymbolicLink(named: name("l"), inDirectory: root(v),
                                               attributes: FSItem.SetAttributesRequest(),
                                               linkContents: name("greeting"))
        } == ENOTSUP)
        #expect(await errnoOf {
            _ = try await v.createLink(to: greeting, named: name("h"), inDirectory: root(v))
        } == ENOTSUP)
        #expect(await errnoOf {
            _ = try await v.createItem(named: name("l"), type: .symlink, inDirectory: root(v),
                                       attributes: FSItem.SetAttributesRequest())
        } == ENOTSUP)
        #expect(b.calls.isEmpty)
    }

    // MARK: AppleDouble (mirror: swallowed)

    @Test func anAppleDoubleCreateNeverReachesTheDriver() async throws {
        let b = seededBackend()
        let v = makeVolume(b)
        let (item, _) = try await v.createItem(named: name("._foo"), type: .file,
                                               inDirectory: root(v),
                                               attributes: FSItem.SetAttributesRequest())
        #expect(b.calls.isEmpty)
        #expect((item as? NTFSItem)?.path == "/._foo")
    }

    @Test func anAppleDoubleWriteIsAcceptedAndWritesNothing() async throws {
        let b = seededBackend()
        let v = makeVolume(b)
        let ghost = v.item(forRecordNumber: 0xFFFF_FFFF_FFFF_FFFE, path: "/._foo",
                           parentRecordNumber: rootRecord)
        let payload = Data("metadata".utf8)
        #expect(try await v.write(contents: payload, to: ghost, at: 0) == payload.count)
        #expect(try read(v, ghost, at: 0, length: 8).isEmpty)
        #expect(b.calls.isEmpty)
        #expect(b.statted.isEmpty)
    }

    // MARK: removing (mirror: dispatch by type)

    @Test func removingDispatchesOnWhatTheDriverSaysTheEntryIs() async throws {
        let b = seededBackend()
        b.nodes["/junction"] = .init(attr: attr(67, .junction))
        let v = makeVolume(b)
        for (path, record) in [("/greeting", 65), ("/sub", 64), ("/link", 66), ("/junction", 67)] {
            let item = v.item(forRecordNumber: UInt64(record), path: path,
                              parentRecordNumber: rootRecord)
            try await v.removeItem(item, named: name(String(path.dropFirst())),
                                   fromDirectory: root(v))
        }
        #expect(b.calls == [.unlink("/greeting"), .rmdir("/sub"),
                            .unlink("/link"), .rmdir("/junction")])
    }

    /// A stat that fails for a reason other than absence must not be
    /// reported as absence: ENOENT tells the caller the file is already
    /// gone, when the driver said it could not tell.
    @Test func aRemoveWhoseStatFailsReportsTheDriversReason() async {
        let b = seededBackend()
        b.statFailures["/greeting"] = EIO
        let v = makeVolume(b)
        let greeting = v.item(forRecordNumber: 65, path: "/greeting", parentRecordNumber: rootRecord)
        let code = await errnoOf {
            try await v.removeItem(greeting, named: name("greeting"), fromDirectory: root(v))
        }
        #expect(code == EIO)
        #expect(b.calls.isEmpty)
    }

    // MARK: writing (mirror: whole-file replace, read-modify-write)

    /// fs_ntfs_write_file_contents_h replaces the whole file, so a write
    /// at an offset reads the file, splices, and writes it all back.
    @Test func aWriteAtAnOffsetRewritesTheWholeMergedFile() async throws {
        let b = seededBackend()
        let v = makeVolume(b)
        let greeting = v.item(forRecordNumber: 65, path: "/greeting", parentRecordNumber: rootRecord)
        let n = try await v.write(contents: Data("world\n".utf8), to: greeting, at: 6)
        #expect(n == 6)
        #expect(b.calls == [.read("/greeting", offset: 0, length: 6),
                            .writeContents("/greeting", length: 12)])
        #expect(b.nodes["/greeting"]?.data == Array("hello\nworld\n".utf8))
    }

    @Test func aWriteFromZeroThatCoversTheFileSkipsTheRead() async throws {
        let b = seededBackend()
        let v = makeVolume(b)
        let greeting = v.item(forRecordNumber: 65, path: "/greeting", parentRecordNumber: rootRecord)
        _ = try await v.write(contents: Data("bonjour".utf8), to: greeting, at: 0)
        #expect(b.calls == [.writeContents("/greeting", length: 7)])
        #expect(b.nodes["/greeting"]?.data == Array("bonjour".utf8))
    }

    /// POSIX write(2): a count of zero "shall return zero and have no
    /// other results". A whole-file rewrite sized to the offset would
    /// grow the file with zeros instead.
    @Test func anEmptyWritePastTheEndChangesNothing() async throws {
        let b = seededBackend()
        let v = makeVolume(b)
        let greeting = v.item(forRecordNumber: 65, path: "/greeting", parentRecordNumber: rootRecord)
        #expect(try await v.write(contents: Data(), to: greeting, at: 100) == 0)
        #expect(b.calls.isEmpty)
        #expect(b.nodes["/greeting"]?.data == Array("hello\n".utf8))
    }

    @Test func aWriteWhoseStatFailsReportsTheDriversReason() async {
        let b = seededBackend()
        b.statFailures["/greeting"] = EIO
        let v = makeVolume(b)
        let greeting = v.item(forRecordNumber: 65, path: "/greeting", parentRecordNumber: rootRecord)
        #expect(await errnoOf {
            _ = try await v.write(contents: Data("x".utf8), to: greeting, at: 0)
        } == EIO)
        #expect(b.calls.isEmpty)
    }

    // MARK: renaming (mirror: basename-only, same directory)

    @Test func aRenameIsOneBasenameRenameInTheSameDirectory() async throws {
        let b = seededBackend()
        let v = makeVolume(b)
        let greeting = v.item(forRecordNumber: 65, path: "/greeting", parentRecordNumber: rootRecord)
        let out = try await v.renameItem(greeting, inDirectory: root(v), named: name("greeting"),
                                         to: name("salut"), inDirectory: root(v), overItem: nil)
        #expect(out.string == "salut")
        #expect(b.calls == [.rename("/greeting", toBasename: "salut")])
    }

    /// WHERE THE MIRROR DISAGREED. It unlinked the destination and then
    /// renamed. The volume leaves the replacement to the driver's rename,
    /// which is atomic: unlinking first lost the original whenever the
    /// rename then failed.
    @Test func aRenameOverAnExistingFileNeverUnlinksTheDestination() async throws {
        let b = seededBackend()
        b.nodes["/b"] = .init(attr: attr(70, .file, size: 1), data: [0x42])
        let v = makeVolume(b)
        let greeting = v.item(forRecordNumber: 65, path: "/greeting", parentRecordNumber: rootRecord)
        let over = v.item(forRecordNumber: 70, path: "/b", parentRecordNumber: rootRecord)
        _ = try await v.renameItem(greeting, inDirectory: root(v), named: name("greeting"),
                                   to: name("b"), inDirectory: root(v), overItem: over)
        #expect(b.calls == [.rename("/greeting", toBasename: "b")])
    }

    /// fs_ntfs_rename2_h takes a new basename only.
    @Test func aRenameIntoAnotherDirectoryIsNotSupported() async {
        let b = seededBackend()
        let v = makeVolume(b)
        let greeting = v.item(forRecordNumber: 65, path: "/greeting", parentRecordNumber: rootRecord)
        let sub = v.item(forRecordNumber: 64, path: "/sub", parentRecordNumber: rootRecord)
        #expect(await errnoOf {
            _ = try await v.renameItem(greeting, inDirectory: root(v), named: name("greeting"),
                                       to: name("greeting"), inDirectory: sub, overItem: nil)
        } == ENOTSUP)
        #expect(b.calls.isEmpty)
    }

    // MARK: truncating (mirror: shrink only)

    @Test func aShrinkingSizeIsATruncate() async throws {
        let b = seededBackend()
        let v = makeVolume(b)
        let greeting = v.item(forRecordNumber: 65, path: "/greeting", parentRecordNumber: rootRecord)
        let request = FSItem.SetAttributesRequest()
        request.size = 2
        let after = try await v.setAttributes(request, on: greeting)
        #expect(b.calls == [.truncate("/greeting", size: 2)])
        #expect(request.consumedAttributes == [.size])
        #expect(after.size == 2)
    }

    /// WHERE THE MIRROR DISAGREED. It modelled a grow as the driver
    /// refusing it; the volume refuses it before the driver is asked.
    @Test func aGrowingSizeIsRefusedWithoutReachingTheDriver() async {
        let b = seededBackend()
        let v = makeVolume(b)
        let greeting = v.item(forRecordNumber: 65, path: "/greeting", parentRecordNumber: rootRecord)
        let request = FSItem.SetAttributesRequest()
        request.size = 100
        #expect(await errnoOf { _ = try await v.setAttributes(request, on: greeting) } == ENOTSUP)
        #expect(b.calls.isEmpty)
        #expect(b.nodes["/greeting"]?.data.count == 6)
    }

    // MARK: times (mirror: FILETIME)

    /// A FILETIME counts 100 ns ticks from 1601-01-01 UTC, which is
    /// 11 644 473 600 seconds before the UNIX epoch.
    @Test func timesAreSetAsFiletimesAndOnlyThoseAsked() async throws {
        let b = seededBackend()
        let v = makeVolume(b)
        let greeting = v.item(forRecordNumber: 65, path: "/greeting", parentRecordNumber: rootRecord)
        let request = FSItem.SetAttributesRequest()
        request.modifyTime = timespec(tv_sec: 0, tv_nsec: 0)
        request.accessTime = timespec(tv_sec: 1_700_000_000, tv_nsec: 500)
        _ = try await v.setAttributes(request, on: greeting)
        #expect(b.calls == [.setTimes("/greeting", NTFSFileTimes(
            creation: nil,
            modification: 116_444_736_000_000_000,
            change: nil,
            access: 133_444_736_000_000_005))])
        #expect(request.consumedAttributes == [.modifyTime, .accessTime])
    }

    /// NTFS has no POSIX owner or mode to set; the request is accepted so
    /// Finder's copy and save flows do not fail, and nothing is written.
    @Test func modeAndOwnersAreAcceptedWithoutReachingTheDriver() async throws {
        let b = seededBackend()
        let v = makeVolume(b)
        let greeting = v.item(forRecordNumber: 65, path: "/greeting", parentRecordNumber: rootRecord)
        let request = FSItem.SetAttributesRequest()
        request.mode = 0o600
        request.uid = 501
        request.gid = 20
        _ = try await v.setAttributes(request, on: greeting)
        #expect(b.calls.isEmpty)
        #expect(request.consumedAttributes == [.mode, .uid, .gid])
    }

    // MARK: attributes

    @Test func attributesCarryTheDriversFieldsAndHideSystemFiles() async throws {
        let b = seededBackend()
        b.nodes["/$MFT"] = .init(attr: attr(0, .file, size: 4096, fileAttributes: 0x0006))
        let v = makeVolume(b)
        let greeting = v.item(forRecordNumber: 65, path: "/greeting", parentRecordNumber: rootRecord)
        let a = try await v.attributes(FSItem.GetAttributesRequest(), of: greeting)
        #expect(a.type == .file)
        #expect(a.size == 6)
        #expect(a.fileID.rawValue == 65)
        #expect(a.parentID.rawValue == rootRecord)
        #expect(a.modifyTime.tv_sec == 1_700_000_002)
        #expect(a.birthTime.tv_sec == 1_600_000_000)
        #expect(a.flags == 0)
        let mft = v.item(forRecordNumber: 0, path: "/$MFT", parentRecordNumber: rootRecord)
        #expect(try await v.attributes(FSItem.GetAttributesRequest(), of: mft).flags
                == UInt32(UF_HIDDEN))
    }

    /// The root's parent is FSKit's FSItemIDParentOfRoot, which is 1.
    @Test func theRootsParentIsFSKitsParentOfRoot() async throws {
        let v = makeVolume(seededBackend())
        let a = try await v.attributes(FSItem.GetAttributesRequest(), of: root(v))
        #expect(a.parentID.rawValue == 1)
        #expect(a.type == .directory)
    }

    @Test func attributesThatCannotBeReadReportTheDriversReason() async {
        let b = seededBackend()
        b.statFailures["/greeting"] = EIO
        let v = makeVolume(b)
        let greeting = v.item(forRecordNumber: 65, path: "/greeting", parentRecordNumber: rootRecord)
        #expect(await errnoOf {
            _ = try await v.attributes(FSItem.GetAttributesRequest(), of: greeting)
        } == EIO)
    }

    @Test func anUnmountedVolumeAnswersEBADF() async {
        let b = seededBackend()
        b.isMounted = false
        let v = makeVolume(b)
        #expect(await errnoOf {
            _ = try await v.attributes(FSItem.GetAttributesRequest(), of: root(v))
        } == EBADF)
        #expect(await errnoOf {
            _ = try await v.lookupItem(named: name("greeting"), inDirectory: root(v))
        } == EBADF)
        #expect(b.statted.isEmpty)
    }

    // MARK: lookup

    @Test func aLookupNamesTheChildAndItsParent() async throws {
        let b = seededBackend()
        let v = makeVolume(b)
        let (item, _) = try await v.lookupItem(named: name("greeting"), inDirectory: root(v))
        let found = try #require(item as? NTFSItem)
        #expect(found.fileRecordNumber == 65)
        #expect(found.path == "/greeting")
        #expect(found.parentRecordNumber == rootRecord)
    }

    @Test func aLookupOfAMissingNameIsENOENT() async {
        let v = makeVolume(seededBackend())
        #expect(await errnoOf {
            _ = try await v.lookupItem(named: name("absent"), inDirectory: root(v))
        } == ENOENT)
    }

    @Test func aLookupThatFailsForAnotherReasonReportsThatReason() async {
        let b = seededBackend()
        b.statFailures["/greeting"] = EACCES
        let v = makeVolume(b)
        #expect(await errnoOf {
            _ = try await v.lookupItem(named: name("greeting"), inDirectory: root(v))
        } == EACCES)
    }

    /// caf\xE9: Latin-1, not UTF-8. NTFS cannot hold such a name, and the
    /// driver would misread it, so it is refused without being asked.
    @Test func aNameThatIsNotUTF8IsRefusedWithoutReachingTheDriver() async {
        let b = seededBackend()
        let v = makeVolume(b)
        let latin1 = FSFileName(data: Data(Array("caf".utf8) + [0xE9]))
        #expect(await errnoOf {
            _ = try await v.lookupItem(named: latin1, inDirectory: root(v))
        } == EILSEQ)
        #expect(b.statted.isEmpty)
    }

    /// FSKit reclaims an item it no longer holds; the next lookup of that
    /// record must build a new one rather than resurrect the reclaimed.
    @Test func aReclaimedItemIsNotHandedOutAgain() async throws {
        let v = makeVolume(seededBackend())
        let (first, _) = try await v.lookupItem(named: name("greeting"), inDirectory: root(v))
        try await v.reclaimItem(first)
        let (second, _) = try await v.lookupItem(named: name("greeting"), inDirectory: root(v))
        #expect(first !== second)
    }

    // MARK: reading

    @Test func aReadAnswersTheDriversBytes() throws {
        let v = makeVolume(seededBackend())
        let greeting = v.item(forRecordNumber: 65, path: "/greeting", parentRecordNumber: rootRecord)
        #expect(try read(v, greeting, at: 1, length: 64) == Array("ello\n".utf8))
        #expect(try read(v, greeting, at: 6, length: 64).isEmpty)
    }

    /// A failed read is an error, not the end of the file: FSKit takes
    /// zero bytes as EOF, so a clamped failure became a short copy.
    @Test func aFailedReadThrowsTheDriversErrnoInsteadOfEndingTheFile() {
        let b = seededBackend()
        b.readFailures["/greeting"] = EIO
        let v = makeVolume(b)
        let greeting = v.item(forRecordNumber: 65, path: "/greeting", parentRecordNumber: rootRecord)
        #expect(throws: (any Error).self) { _ = try read(v, greeting, at: 0, length: 8) }
        do {
            _ = try read(v, greeting, at: 0, length: 8)
        } catch {
            #expect((error as NSError).domain == NSPOSIXErrorDomain)
            #expect((error as NSError).code == Int(EIO))
        }
    }

    @Test func aSymbolicLinkAnswersItsTargetsBytes() async throws {
        let v = makeVolume(seededBackend())
        let link = v.item(forRecordNumber: 66, path: "/link", parentRecordNumber: rootRecord)
        #expect(try await v.readSymbolicLink(link).data == Data("greeting".utf8))
    }

    @Test func aSymlinkThatCannotBeReadReportsTheDriversReason() async {
        let v = makeVolume(seededBackend())
        let greeting = v.item(forRecordNumber: 65, path: "/greeting", parentRecordNumber: rootRecord)
        #expect(await errnoOf { _ = try await v.readSymbolicLink(greeting) } == EINVAL)
    }

    // MARK: listing

    /// fs_ntfs_dir_open synthesises "." and ".." first. FSKit wants them
    /// when no attributes are asked for.
    @Test func aListingWithoutAttributesIncludesTheDotsAndRisingCookies() throws {
        let v = makeVolume(seededBackend())
        let (entries, end) = try list(v, root(v))
        #expect(entries.map { $0.name.string } == [".", "..", "greeting", "link", "sub"])
        #expect(entries.map { $0.itemID.rawValue } == [5, 5, 65, 66, 64])
        #expect(entries.map { $0.itemType } == [.directory, .directory, .file, .symlink, .directory])
        #expect(entries.map { $0.nextCookie.rawValue } == [1, 2, 3, 4, 5])
        #expect(end == 6)
    }

    @Test func aListingResumesAfterTheCookieItWasGiven() throws {
        let v = makeVolume(seededBackend())
        let (entries, _) = try list(v, root(v), after: 3)
        #expect(entries.map { $0.name.string } == ["link", "sub"])
    }

    /// A full packer stops the walk, and the cookie returned is the one
    /// the next call must resume from — so nothing is skipped or repeated.
    @Test func aFullPackerStopsAtAnEntryTheNextCallReturns() throws {
        let v = makeVolume(seededBackend())
        let first = try list(v, root(v), room: 3)
        #expect(first.entries.map { $0.name.string } == [".", "..", "greeting"])
        let second = try list(v, root(v), after: first.entries.last!.nextCookie.rawValue)
        #expect(second.entries.map { $0.name.string } == ["link", "sub"])
    }

    /// FSVolume.h: "Don't pack "." and ".." if `attributes` isn't nil."
    @Test func aListingWithAttributesPacksNoDots() throws {
        let v = makeVolume(seededBackend())
        let (entries, _) = try list(v, root(v), withAttributes: true)
        #expect(entries.map { $0.name.string } == ["greeting", "link", "sub"])
    }

    @Test func aListingWithAttributesGivesEachChildItsDirectoryAsParent() throws {
        let v = makeVolume(seededBackend())
        let (entries, _) = try list(v, root(v), withAttributes: true)
        let greeting = try #require(entries.first { $0.name.string == "greeting" }?.attributes)
        #expect(greeting.fileID.rawValue == 65)
        #expect(greeting.parentID.rawValue == rootRecord)
        #expect(greeting.size == 6)
    }

    @Test func aDirectoryThatCannotBeOpenedReportsTheDriversReason() {
        let b = seededBackend()
        b.openFailures["/sub"] = ENOTDIR
        let v = makeVolume(b)
        let sub = v.item(forRecordNumber: 64, path: "/sub", parentRecordNumber: rootRecord)
        do {
            _ = try list(v, sub)
            Issue.record("the listing succeeded")
        } catch {
            #expect((error as NSError).code == Int(ENOTDIR))
        }
    }

    // MARK: activation, fsck and deactivation

    /// A read-write mount defers the dirty check and fsck to the first
    /// activate, where the device is writable; a plain device goes through
    /// the callback fsck.
    @Test func activatingAWritableMountRunsFsckOnceOnly() {
        let b = seededBackend()
        let v = makeVolume(b, requiresFsckRemount: true)
        let root = v.activatedRoot()
        _ = v.activatedRoot()
        #expect(b.calls == [.fsck])
        #expect(root.fileRecordNumber == rootRecord)
        #expect(root.path == "/")
    }

    @Test func activatingAContainerOrPartitionRemountsThroughTheDeviceChain() {
        let b = seededBackend()
        b.remountsThroughDeviceChain = true
        _ = makeVolume(b, requiresFsckRemount: true).activatedRoot()
        #expect(b.calls == [.remountThroughDeviceChain])
    }

    @Test func activatingAReadOnlyMountTouchesNothing() {
        let b = seededBackend()
        _ = makeVolume(b, requiresFsckRemount: false).activatedRoot()
        #expect(b.calls.isEmpty)
    }

    /// An fsck that fails leaves a volume that can still be read, so the
    /// mount goes ahead and the failure is reported, not thrown.
    @Test func aFailedFsckStillActivatesTheRoot() {
        let b = seededBackend()
        b.fsckResult = .failure(POSIXError(.EIO))
        let root = makeVolume(b, requiresFsckRemount: true).activatedRoot()
        #expect(b.calls == [.fsck])
        #expect(root.fileRecordNumber == rootRecord)
    }

    @Test func runFsckHandsBackTheDriversReport() throws {
        let b = seededBackend()
        let report = NTFSVolume.FsckReport(wasDirty: true, dirtyCleared: true)
        b.fsckResult = .success(report)
        let result = makeVolume(b).runFsck(onProgress: { _, _, _ in }, onFinding: { _ in })
        #expect(try result.get() == report)
        #expect(report.toEventFields() == ["dirty_cleared": "true"])
    }

    /// The device context the C callbacks read through must outlive the
    /// handle that holds those callbacks.
    @Test func deactivatingUnmountsBeforeReleasingTheDevice() {
        let b = seededBackend()
        makeVolume(b).deactivateNow()
        #expect(b.calls == [.unmount, .releaseDevice])
    }
}
