//
//  EXT4VolumeOperationsTests.swift — the REAL EXT4Volume's mutating and
//  failing operations, over a backend that records every call.
//
//  WHAT THIS REPLACES
//  ------------------
//  `DiskJockeyTests/EXT4VolumeTests.swift` held thirteen cases against a
//  "local mirror" of FileSystemBackend and hand-written "drivers" that
//  reproduced the volume's wiring. They never loaded EXT4Volume, and two
//  of them asserted the opposite of what it does (diskjockey#196):
//
//    - a write at an offset was mirrored as a read-modify-write through
//      the whole-file writeFile. The volume has written with pwrite, and
//      only the bytes touched, since that path was measured O(N²) and
//      overflowed the journal's descriptor block.
//    - a rename over an existing file was mirrored as unlink-then-rename.
//      The volume deliberately does not unlink: the driver's rename
//      replaces atomically, and unlinking first lost the file when the
//      rename then failed.
//
//  Every case here calls the production method. Expected values come from
//  FileSystemBackend's contract or from POSIX, never from the body under
//  test.
//
//  Host-free: the real EXT4Volume over RecordingBackend.
//

import Foundation
import FSKit
import Testing
@testable import DiskJockeyEXT4Core
@testable import DiskJockeyLibrary

// MARK: - A backend that records what it is asked

private final class RecordingBackend: FileSystemBackend {

    enum Call: Equatable {
        case createFile(String, mode: UInt16)
        case mkdir(String, mode: UInt16)
        case writeFile(String, length: UInt64)
        case pwrite(String, offset: UInt64, length: UInt64)
        case readFile(String)
        case unlink(String)
        case rmdir(String)
        case rename(String, String)
        case chown(String, uid: UInt32?, gid: UInt32?)
        case symlink(target: [UInt8], String)
        case flush
        case replayJournal
    }

    let pathEncoding: DriverPathEncoding = .bytes
    private(set) var calls: [Call] = []

    /// What `stat` answers, by path; a missing path fails with ENOENT.
    var nodes: [String: BackendFileType] = ["/": .directory]
    /// Paths whose stat fails with this errno instead.
    var statFailures: [String: Int32] = [:]
    var pwriteFails = false
    var readlinkFails = false
    var replayJournalSucceeds = true
    var errno: Int32 = 0

    func lastErrno() -> Int32 { errno }
    func lastErrorMessage() -> String { "(recording backend)" }

    func stat(path: VolumePath) -> BackendFileAttributes? {
        let key = path.description
        if let e = statFailures[key] { errno = e; return nil }
        guard let type = nodes[key] else { errno = ENOENT; return nil }
        return BackendFileAttributes(fileID: key == "/" ? 2 : UInt64(12 + key.count),
                                     fileType: type, mode: 0o644, uid: 0, gid: 0,
                                     size: 0, linkCount: 1,
                                     atime: 0, mtime: 0, ctime: 0, crtime: 0)
    }
    func createFile(path: VolumePath, mode: UInt16) -> Bool {
        calls.append(.createFile(path.description, mode: mode))
        nodes[path.description] = .file
        return true
    }
    func mkdir(path: VolumePath, mode: UInt16) -> Bool {
        calls.append(.mkdir(path.description, mode: mode))
        nodes[path.description] = .directory
        return true
    }
    func writeFile(path: VolumePath, data: UnsafeRawPointer, length: UInt64) -> Int64 {
        calls.append(.writeFile(path.description, length: length))
        return Int64(length)
    }
    func pwrite(path: VolumePath, offset: UInt64,
                data: UnsafeRawPointer, length: UInt64) -> Int64 {
        calls.append(.pwrite(path.description, offset: offset, length: length))
        if pwriteFails { errno = ENOSPC; return -1 }
        return Int64(length)
    }
    func readFile(path: VolumePath, offset: UInt64, length: UInt64,
                  buffer: UnsafeMutableRawPointer) -> Int64 {
        calls.append(.readFile(path.description))
        return 0
    }
    func unlink(path: VolumePath) -> Bool {
        calls.append(.unlink(path.description)); nodes[path.description] = nil; return true
    }
    func rmdir(path: VolumePath) -> Bool {
        calls.append(.rmdir(path.description)); nodes[path.description] = nil; return true
    }
    func rename(src: VolumePath, dst: VolumePath) -> Bool {
        calls.append(.rename(src.description, dst.description))
        nodes[dst.description] = nodes.removeValue(forKey: src.description)
        return true
    }
    func chown(path: VolumePath, uid: UInt32?, gid: UInt32?) -> Bool {
        calls.append(.chown(path.description, uid: uid, gid: gid)); return true
    }
    func symlink(target: [UInt8], linkpath: VolumePath) -> Bool {
        calls.append(.symlink(target: target, linkpath.description))
        nodes[linkpath.description] = .symlink
        return true
    }
    func readSymlink(path: VolumePath) -> [UInt8]? {
        if readlinkFails { errno = EINVAL; return nil }
        return Array("target".utf8)
    }
    func flush() -> Bool { calls.append(.flush); return true }
    func replayJournalIfDirty() -> Bool {
        calls.append(.replayJournal)
        return replayJournalSucceeds
    }

    func volumeInfo() -> BackendVolumeInfo { unreachable() }
    func shutdown() {}
    func readDirectory(path: VolumePath) -> [BackendDirectoryEntry]? { unreachable() }
    func truncate(path: VolumePath, size: UInt64) -> Bool { unreachable() }
    func chmod(path: VolumePath, mode: UInt16) -> Bool { unreachable() }
    func link(src: VolumePath, dst: VolumePath) -> Bool { unreachable() }
    func utimens(path: VolumePath, atime: timespec?, mtime: timespec?) -> Bool { true }

    private func unreachable(_ function: String = #function) -> Never {
        fatalError("RecordingBackend.\(function) was called; these tests do not reach it")
    }
}

private func makeVolume(_ backend: RecordingBackend,
                        requiresJournalReplay: Bool = false,
                        opLock: OperationLock = OperationLock()) -> EXT4Volume {
    EXT4Volume(volumeID: FSVolume.Identifier(uuid: UUID()),
               volumeName: FSFileName(string: "test"),
               backend: backend,
               requiresJournalReplay: requiresJournalReplay,
               stats: IOStatsCollector(label: "test", emit: { _ in }),
               opLock: opLock)
}

private func posixCode(_ body: () async throws -> Void) async -> POSIXErrorCode? {
    do { try await body(); return nil }
    catch let e as POSIXError { return e.code }
    catch { return nil }
}

private func name(_ s: String) -> FSFileName { FSFileName(string: s) }

// MARK: - Tests

@Suite("EXT4Volume operations")
struct EXT4VolumeOperationsTests {

    // MARK: creating

    @Test func creatingAFileAsksTheBackendForItWithTheDefaultMode() async throws {
        let b = RecordingBackend()
        let v = makeVolume(b)
        let root = v.item(forID: 2, path: "/", parentInode: nil)
        let (item, _) = try await v.createItem(named: name("foo.txt"), type: .file,
                                               inDirectory: root,
                                               attributes: FSItem.SetAttributesRequest())
        #expect(b.calls == [.createFile("/foo.txt", mode: 0o644)])
        #expect((item as? EXT4Item)?.path == "/foo.txt")
    }

    @Test func creatingAFileInASubdirectoryKeepsTheModeItWasGiven() async throws {
        let b = RecordingBackend()
        b.nodes["/sub"] = .directory
        let v = makeVolume(b)
        let sub = v.item(forID: 20, path: "/sub", parentInode: 2)
        let request = FSItem.SetAttributesRequest()
        request.mode = 0o600
        _ = try await v.createItem(named: name("bar"), type: .file,
                                   inDirectory: sub, attributes: request)
        #expect(b.calls == [.createFile("/sub/bar", mode: 0o600)])
    }

    @Test func creatingADirectoryIsAMkdirWithTheDirectoryDefault() async throws {
        let b = RecordingBackend()
        let v = makeVolume(b)
        let root = v.item(forID: 2, path: "/", parentInode: nil)
        _ = try await v.createItem(named: name("d"), type: .directory, inDirectory: root,
                                   attributes: FSItem.SetAttributesRequest())
        #expect(b.calls == [.mkdir("/d", mode: 0o755)])
    }

    @Test func aSymbolicLinkStoresItsTargetsBytes() async throws {
        let b = RecordingBackend()
        let v = makeVolume(b)
        let root = v.item(forID: 2, path: "/", parentInode: nil)
        _ = try await v.createSymbolicLink(named: name("link"), inDirectory: root,
                                           attributes: FSItem.SetAttributesRequest(),
                                           linkContents: name("../target"))
        #expect(b.calls == [.symlink(target: Array("../target".utf8), "/link")])
    }

    // MARK: removing

    @Test func removingDispatchesOnWhatTheBackendSaysTheEntryIs() async throws {
        let b = RecordingBackend()
        b.nodes["/file"] = .file
        b.nodes["/dir"] = .directory
        let v = makeVolume(b)
        let root = v.item(forID: 2, path: "/", parentInode: nil)
        let file = v.item(forID: 17, path: "/file", parentInode: 2)
        let dir = v.item(forID: 16, path: "/dir", parentInode: 2)
        try await v.removeItem(file, named: name("file"), fromDirectory: root)
        try await v.removeItem(dir, named: name("dir"), fromDirectory: root)
        #expect(b.calls == [.unlink("/file"), .rmdir("/dir")])
    }

    /// A stat that fails for a reason other than absence must not be
    /// reported as absence: ENOENT tells the caller the file is already
    /// gone, when the backend said it could not tell.
    @Test func aRemoveWhoseStatFailsReportsTheBackendsReason() async {
        let b = RecordingBackend()
        b.nodes["/file"] = .file
        b.statFailures["/file"] = EIO
        let v = makeVolume(b)
        let root = v.item(forID: 2, path: "/", parentInode: nil)
        let file = v.item(forID: 17, path: "/file", parentInode: 2)
        let code = await posixCode {
            try await v.removeItem(file, named: name("file"), fromDirectory: root)
        }
        #expect(code == .EIO)
        #expect(b.calls.isEmpty)
    }

    // MARK: writing

    /// THE FIRST DEFECT THE MIRROR HID. It modelled a write at an offset as
    /// a read of the whole file and a whole-file writeFile of the merged
    /// bytes. The volume writes the touched bytes, once, at their offset.
    @Test func aWriteAtAnOffsetIsOnePositionalWriteOfOnlyThoseBytes() async throws {
        let b = RecordingBackend()
        b.nodes["/greeting"] = .file
        let v = makeVolume(b)
        let file = v.item(forID: 21, path: "/greeting", parentInode: 2)
        let n = try await v.write(contents: Data("world\n".utf8), to: file, at: 6)
        #expect(n == 6)
        #expect(b.calls == [.pwrite("/greeting", offset: 6, length: 6)])
    }

    @Test func anEmptyWriteReachesNothing() async throws {
        let b = RecordingBackend()
        let v = makeVolume(b)
        let file = v.item(forID: 21, path: "/greeting", parentInode: 2)
        #expect(try await v.write(contents: Data(), to: file, at: 0) == 0)
        #expect(b.calls.isEmpty)
    }

    @Test func aFailedWriteReportsTheBackendsErrno() async {
        let b = RecordingBackend()
        b.pwriteFails = true
        let v = makeVolume(b)
        let file = v.item(forID: 21, path: "/greeting", parentInode: 2)
        let code = await posixCode { _ = try await v.write(contents: Data("x".utf8), to: file, at: 0) }
        #expect(code == .ENOSPC)
    }

    // MARK: renaming

    @Test func aRenameIsOneBackendRename() async throws {
        let b = RecordingBackend()
        b.nodes["/a"] = .file
        let v = makeVolume(b)
        let root = v.item(forID: 2, path: "/", parentInode: nil)
        let a = v.item(forID: 14, path: "/a", parentInode: 2)
        _ = try await v.renameItem(a, inDirectory: root, named: name("a"),
                                   to: name("b"), inDirectory: root, overItem: nil)
        #expect(b.calls == [.rename("/a", "/b")])
    }

    /// THE SECOND DEFECT THE MIRROR HID. It unlinked the destination and
    /// then renamed. The volume leaves the replacement to the backend's
    /// rename, which is atomic: unlinking first lost the original whenever
    /// the rename then failed.
    @Test func aRenameOverAnExistingFileNeverUnlinksTheDestination() async throws {
        let b = RecordingBackend()
        b.nodes["/a"] = .file
        b.nodes["/b"] = .file
        let v = makeVolume(b)
        let root = v.item(forID: 2, path: "/", parentInode: nil)
        let a = v.item(forID: 14, path: "/a", parentInode: 2)
        let over = v.item(forID: 15, path: "/b", parentInode: 2)
        _ = try await v.renameItem(a, inDirectory: root, named: name("a"),
                                   to: name("b"), inDirectory: root, overItem: over)
        #expect(b.calls == [.rename("/a", "/b")])
    }

    // MARK: attributes

    @Test func settingOnlyTheGroupLeavesTheOwnerAlone() async throws {
        let b = RecordingBackend()
        b.nodes["/x"] = .file
        let v = makeVolume(b)
        let x = v.item(forID: 14, path: "/x", parentInode: 2)
        let request = FSItem.SetAttributesRequest()
        request.gid = 300
        _ = try await v.setAttributes(request, on: x)
        #expect(b.calls == [.chown("/x", uid: nil, gid: 300)])
        #expect(request.consumedAttributes == [.gid])
    }

    @Test func attributesThatCannotBeReadReportTheBackendsReason() async {
        let b = RecordingBackend()
        b.statFailures["/x"] = EIO
        let v = makeVolume(b)
        let x = v.item(forID: 14, path: "/x", parentInode: 2)
        let code = await posixCode { _ = try await v.attributes(FSItem.GetAttributesRequest(), of: x) }
        #expect(code == .EIO)
    }

    @Test func aLookupThatFailsForAnotherReasonReportsThatReason() async {
        let b = RecordingBackend()
        b.statFailures["/x"] = EACCES
        let v = makeVolume(b)
        let root = v.item(forID: 2, path: "/", parentInode: nil)
        let code = await posixCode { _ = try await v.lookupItem(named: name("x"), inDirectory: root) }
        #expect(code == .EACCES)
    }

    @Test func aLookupOfAMissingNameIsENOENT() async {
        let v = makeVolume(RecordingBackend())
        let root = v.item(forID: 2, path: "/", parentInode: nil)
        let code = await posixCode { _ = try await v.lookupItem(named: name("x"), inDirectory: root) }
        #expect(code == .ENOENT)
    }

    @Test func aSymlinkThatCannotBeReadReportsTheBackendsReason() async {
        let b = RecordingBackend()
        b.readlinkFails = true
        let v = makeVolume(b)
        let link = v.item(forID: 14, path: "/link", parentInode: 2)
        let code = await posixCode { _ = try await v.readSymbolicLink(link) }
        #expect(code == .EINVAL)
    }

    // MARK: the item cache

    /// FSKit reclaims an item it no longer holds; the next lookup of that
    /// inode must build a new one rather than resurrect the reclaimed.
    @Test func aReclaimedItemIsNotHandedOutAgain() async throws {
        let b = RecordingBackend()
        b.nodes["/x"] = .file
        let v = makeVolume(b)
        let root = v.item(forID: 2, path: "/", parentInode: nil)
        let (first, _) = try await v.lookupItem(named: name("x"), inDirectory: root)
        try await v.reclaimItem(first)
        let (second, _) = try await v.lookupItem(named: name("x"), inDirectory: root)
        #expect(first !== second)
    }

    // MARK: sync and activation

    @Test func synchronizeFlushesTheBackendOnce() async throws {
        let b = RecordingBackend()
        try await makeVolume(b).synchronize(flags: .wait)
        #expect(b.calls == [.flush])
    }

    /// A read-write mount defers the journal replay to the first activate.
    @Test func activatingAVolumeThatNeedsReplayReplaysOnce() {
        let b = RecordingBackend()
        let root = makeVolume(b, requiresJournalReplay: true).activatedRoot()
        #expect(b.calls == [.replayJournal])
        #expect(root.inode == 2)
    }

    @Test func activatingAReadOnlyMountNeverTouchesTheJournal() {
        let b = RecordingBackend()
        _ = makeVolume(b, requiresJournalReplay: false).activatedRoot()
        #expect(b.calls.isEmpty)
    }

    /// A replay that fails leaves a volume that can still be read, so the
    /// mount goes ahead and the failure is reported, not thrown.
    @Test func aFailedReplayStillActivatesTheRoot() {
        let b = RecordingBackend()
        b.replayJournalSucceeds = false
        let root = makeVolume(b, requiresJournalReplay: true).activatedRoot()
        #expect(b.calls == [.replayJournal])
        #expect(root.path == "/")
    }

    // MARK: the check the system runs while mounting (diskjockey#166)

    /// `diskutil mount` on a read-only resource: load, a `-q` check, and a
    /// mount that fails with the log ending at `fsck.done`. A read-only
    /// load has no journal replay in `activate`, so nothing holds the
    /// mount back while the check still holds the lock, and the first
    /// thing a mount asks of a volume is its root. That must be answered.
    @Test func theRootIsAnsweredWhileTheMountsQuickCheckHoldsTheLock() async throws {
        let b = RecordingBackend()
        b.nodes["/x"] = .file
        let lock = OperationLock()
        let v = makeVolume(b, requiresJournalReplay: false, opLock: lock)
        #expect(lock.tryAcquire(FsckOperation(checkOptions: ["-q"])) == nil)

        let root = v.activatedRoot()
        let code = await posixCode {
            _ = try await v.attributes(FSItem.GetAttributesRequest(), of: root)
            _ = try await v.lookupItem(named: name("x"), inDirectory: root)
        }
        #expect(code == nil,
                "the mount's own root operations were refused (\(String(describing: code))) by the quick check it is waiting on")
    }

    /// The quiesce a person asks for is unchanged: during a verify or a
    /// repair of a mounted volume, its operations are still refused.
    @Test("a verify or repair still refuses the volume's operations",
          arguments: [FsckOperation.verify, .repair])
    func aVerifyOrRepairStillRefuses(op: FsckOperation) async {
        let lock = OperationLock()
        let v = makeVolume(RecordingBackend(), opLock: lock)
        #expect(lock.tryAcquire(op) == nil)
        let root = v.item(forID: 2, path: "/", parentInode: nil)
        let code = await posixCode {
            _ = try await v.attributes(FSItem.GetAttributesRequest(), of: root)
        }
        #expect(code == .EBUSY)
    }
}
