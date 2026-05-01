//
//  EXT4VolumeTests.swift — exercises the FileSystemBackend protocol
//  surface (extended for read-write) via a mock that records every call.
//
//  The real `FileSystemBackend` protocol lives inside the DiskJockeyEXT4
//  extension target and isn't visible here, so we define a local mirror
//  with the same method shapes. The point is to validate the call
//  patterns the volume relies on — createItem(.file) routes to
//  createFile, removeItem dispatches by stat type, write at offset does
//  read-modify-write, etc. — independently of FSKit framework types
//  (which can't easily be constructed in a unit test bundle).
//

import Foundation
import Testing
@testable import DiskJockey

// MARK: - Local protocol mirror

private enum MockFileType {
    case file
    case directory
    case symlink
}

private struct MockEntry {
    var type: MockFileType
    var data: Data
    var mode: UInt16
    var uid: UInt32
    var gid: UInt32
    var symlinkTarget: String?
}

private final class MockBackend {

    enum Call: Equatable {
        case createFile(path: String, mode: UInt16)
        case writeFile(path: String, length: UInt64)
        case unlink(path: String)
        case rename(src: String, dst: String)
        case mkdir(path: String, mode: UInt16)
        case rmdir(path: String)
        case symlink(target: String, linkpath: String)
        case link(src: String, dst: String)
        case chmod(path: String, mode: UInt16)
        case chown(path: String, uid: UInt32?, gid: UInt32?)
        case truncate(path: String, size: UInt64)
        case stat(path: String)
        case readFile(path: String, offset: UInt64, length: UInt64)
        case readDirectory(path: String)
        case flush
        case replayJournalIfDirty
    }

    private(set) var calls: [Call] = []
    private(set) var entries: [String: MockEntry] = [
        "/": MockEntry(type: .directory, data: Data(),
                       mode: 0o755, uid: 0, gid: 0, symlinkTarget: nil)
    ]
    private var lastErrno_: Int32 = 0

    /// Tunable behavior for `replayJournalIfDirty`. Default true ==
    /// success/clean. Tests flip to false to model a journal-replay
    /// failure path.
    var replayJournalReturn: Bool = true

    /// Counts how many times `replayJournalIfDirty()` was invoked. Used
    /// by the activate-replay tests to confirm the volume's gating
    /// works (called on RW mount, skipped on RO).
    private(set) var replayJournalCallCount: Int = 0

    func reset() {
        calls.removeAll()
        lastErrno_ = 0
        replayJournalCallCount = 0
    }

    func setLastErrno(_ e: Int32) { lastErrno_ = e }
    func lastErrno() -> Int32 { lastErrno_ }

    func stat(path: String) -> MockEntry? {
        calls.append(.stat(path: path))
        if let e = entries[path] { return e }
        lastErrno_ = ENOENT
        return nil
    }

    func createFile(path: String, mode: UInt16) -> Bool {
        calls.append(.createFile(path: path, mode: mode))
        guard entries[path] == nil else { lastErrno_ = EEXIST; return false }
        entries[path] = MockEntry(type: .file, data: Data(),
                                  mode: mode, uid: 0, gid: 0, symlinkTarget: nil)
        return true
    }

    func writeFile(path: String, data: Data) -> Int64 {
        calls.append(.writeFile(path: path, length: UInt64(data.count)))
        guard var e = entries[path], e.type == .file else {
            lastErrno_ = ENOENT
            return -1
        }
        e.data = data
        entries[path] = e
        return Int64(data.count)
    }

    func unlink(path: String) -> Bool {
        calls.append(.unlink(path: path))
        guard let e = entries[path] else { lastErrno_ = ENOENT; return false }
        if e.type == .directory { lastErrno_ = EISDIR; return false }
        entries.removeValue(forKey: path)
        return true
    }

    func rename(src: String, dst: String) -> Bool {
        calls.append(.rename(src: src, dst: dst))
        guard let e = entries[src] else { lastErrno_ = ENOENT; return false }
        guard entries[dst] == nil else { lastErrno_ = EEXIST; return false }
        entries.removeValue(forKey: src)
        entries[dst] = e
        return true
    }

    func mkdir(path: String, mode: UInt16) -> Bool {
        calls.append(.mkdir(path: path, mode: mode))
        guard entries[path] == nil else { lastErrno_ = EEXIST; return false }
        entries[path] = MockEntry(type: .directory, data: Data(),
                                  mode: mode, uid: 0, gid: 0, symlinkTarget: nil)
        return true
    }

    func rmdir(path: String) -> Bool {
        calls.append(.rmdir(path: path))
        guard let e = entries[path] else { lastErrno_ = ENOENT; return false }
        guard e.type == .directory else { lastErrno_ = ENOTDIR; return false }
        entries.removeValue(forKey: path)
        return true
    }

    func symlink(target: String, linkpath: String) -> Bool {
        calls.append(.symlink(target: target, linkpath: linkpath))
        guard entries[linkpath] == nil else { lastErrno_ = EEXIST; return false }
        entries[linkpath] = MockEntry(type: .symlink, data: Data(),
                                      mode: 0o777, uid: 0, gid: 0,
                                      symlinkTarget: target)
        return true
    }

    func link(src: String, dst: String) -> Bool {
        calls.append(.link(src: src, dst: dst))
        guard let e = entries[src] else { lastErrno_ = ENOENT; return false }
        guard entries[dst] == nil else { lastErrno_ = EEXIST; return false }
        entries[dst] = e
        return true
    }

    func chmod(path: String, mode: UInt16) -> Bool {
        calls.append(.chmod(path: path, mode: mode))
        guard var e = entries[path] else { lastErrno_ = ENOENT; return false }
        e.mode = mode
        entries[path] = e
        return true
    }

    func chown(path: String, uid: UInt32?, gid: UInt32?) -> Bool {
        calls.append(.chown(path: path, uid: uid, gid: gid))
        guard var e = entries[path] else { lastErrno_ = ENOENT; return false }
        if let u = uid { e.uid = u }
        if let g = gid { e.gid = g }
        entries[path] = e
        return true
    }

    func truncate(path: String, size: UInt64) -> Bool {
        calls.append(.truncate(path: path, size: size))
        guard var e = entries[path], e.type == .file else {
            lastErrno_ = ENOENT
            return false
        }
        if UInt64(e.data.count) > size {
            e.data = e.data.prefix(Int(size))
        }
        entries[path] = e
        return true
    }

    func readFile(path: String, offset: UInt64, length: UInt64) -> Data? {
        calls.append(.readFile(path: path, offset: offset, length: length))
        guard let e = entries[path], e.type == .file else { return nil }
        let start = min(Int(offset), e.data.count)
        let end = min(start + Int(length), e.data.count)
        return e.data.subdata(in: start..<end)
    }

    func flush() -> Bool {
        calls.append(.flush)
        return true
    }

    func replayJournalIfDirty() -> Bool {
        calls.append(.replayJournalIfDirty)
        replayJournalCallCount += 1
        return replayJournalReturn
    }
}

// MARK: - Drivers — pure logic helpers that mirror the volume's wiring

/// Reproduces the Volume's path-join behaviour so we can test the call
/// pattern without dragging in FSKit.
private func joinPath(_ parent: String, _ child: String) -> String {
    return parent == "/" ? "/\(child)" : "\(parent)/\(child)"
}

/// Drives MockBackend the same way EXT4Volume.createItem does for files.
private func driveCreateItemFile(name: String, parent: String,
                                 mode: UInt16, mock: MockBackend) -> Bool {
    let child = joinPath(parent, name)
    return mock.createFile(path: child, mode: mode)
}

/// Drives MockBackend the same way EXT4Volume.removeItem does — stat
/// first, then dispatch to unlink or rmdir based on the entry type.
private func driveRemoveItem(name: String, parent: String,
                             mock: MockBackend) -> Bool {
    let child = joinPath(parent, name)
    guard let entry = mock.stat(path: child) else { return false }
    switch entry.type {
    case .directory: return mock.rmdir(path: child)
    default:         return mock.unlink(path: child)
    }
}

/// Drives MockBackend the same way EXT4Volume.write(contents:to:at:) does
/// for offset writes — read-modify-write through the whole-file replace
/// API.
private func driveWriteAt(path: String, offset: UInt64, data: Data,
                          mock: MockBackend) -> Bool {
    guard let entry = mock.stat(path: path), entry.type == .file else { return false }
    let currentSize = UInt64(entry.data.count)
    let newEnd = offset + UInt64(data.count)
    let mergedSize = max(currentSize, newEnd)

    if offset == 0 && UInt64(data.count) >= currentSize {
        return mock.writeFile(path: path, data: data) >= 0
    }

    var buf = Data(count: Int(mergedSize))
    if currentSize > 0,
       let existing = mock.readFile(path: path, offset: 0, length: currentSize) {
        buf.replaceSubrange(0..<existing.count, with: existing)
    }
    buf.replaceSubrange(Int(offset)..<Int(offset)+data.count, with: data)
    return mock.writeFile(path: path, data: buf) >= 0
}

/// Drives MockBackend the same way `EXT4Volume.activate(options:)` does.
/// Mirrors the gate: replay is invoked only when `requiresJournalReplay`
/// is true, and a `false` return from the backend is logged but does
/// NOT propagate as a thrown error — the activate call still succeeds.
/// Returns `true` if the activate would have returned the root item,
/// matching the real implementation which never throws on this path.
private func driveActivate(requiresJournalReplay: Bool,
                           mock: MockBackend) -> Bool {
    if requiresJournalReplay {
        // The real volume logs success / failure but always proceeds —
        // the boolean is intentionally discarded here, just like the
        // production path.
        _ = mock.replayJournalIfDirty()
    }
    // The real activate returns the root FSItem unconditionally — model
    // that as "true" since constructing an FSItem requires FSKit types
    // which aren't visible to this test bundle.
    return true
}

/// Drives MockBackend the same way EXT4Volume.renameItem does, including
/// the "remove existing destination first" branch when overItem is set.
private func driveRename(srcParent: String, srcName: String,
                         dstParent: String, dstName: String,
                         hasOverItem: Bool,
                         mock: MockBackend) -> Bool {
    let src = joinPath(srcParent, srcName)
    let dst = joinPath(dstParent, dstName)
    if hasOverItem {
        if let dstEntry = mock.stat(path: dst) {
            let removed: Bool
            switch dstEntry.type {
            case .directory: removed = mock.rmdir(path: dst)
            default:         removed = mock.unlink(path: dst)
            }
            if !removed { return false }
        }
    }
    return mock.rename(src: src, dst: dst)
}

// MARK: - Tests

struct EXT4VolumeTests {

    @Test func testCreateFileSucceeds() throws {
        let mock = MockBackend()
        let ok = driveCreateItemFile(name: "foo.txt", parent: "/",
                                     mode: 0o644, mock: mock)
        #expect(ok)
        #expect(mock.calls.contains(.createFile(path: "/foo.txt", mode: 0o644)))
        #expect(mock.entries["/foo.txt"] != nil)
    }

    @Test func testCreateFileInSubdirectory() throws {
        let mock = MockBackend()
        // Pre-seed a directory.
        _ = mock.mkdir(path: "/sub", mode: 0o755)
        mock.reset()
        let ok = driveCreateItemFile(name: "bar", parent: "/sub",
                                     mode: 0o600, mock: mock)
        #expect(ok)
        #expect(mock.calls == [.createFile(path: "/sub/bar", mode: 0o600)])
    }

    @Test func testRemoveItemDispatchesByType() throws {
        let mock = MockBackend()
        _ = mock.createFile(path: "/file", mode: 0o644)
        _ = mock.mkdir(path: "/dir", mode: 0o755)
        mock.reset()

        #expect(driveRemoveItem(name: "file", parent: "/", mock: mock))
        #expect(driveRemoveItem(name: "dir",  parent: "/", mock: mock))

        // Filter just the dispatch decisions, not the stat calls that
        // precede them — both dispatches must land on the right primitive.
        let ops = mock.calls.filter {
            if case .stat = $0 { return false }
            return true
        }
        #expect(ops == [.unlink(path: "/file"), .rmdir(path: "/dir")])
    }

    @Test func testWriteAtOffsetReadModifyWrite() throws {
        let mock = MockBackend()
        _ = mock.createFile(path: "/greeting", mode: 0o644)
        _ = mock.writeFile(path: "/greeting", data: Data("hello\n".utf8))
        mock.reset()

        let payload = Data("world\n".utf8)
        let ok = driveWriteAt(path: "/greeting", offset: 6,
                              data: payload, mock: mock)
        #expect(ok)
        #expect(mock.entries["/greeting"]?.data == Data("hello\nworld\n".utf8))

        // Exactly one writeFile must have happened, with the merged size.
        let writeCalls = mock.calls.compactMap { call -> UInt64? in
            if case let .writeFile(_, length) = call { return length }
            return nil
        }
        #expect(writeCalls == [12])
    }

    @Test func testWriteFastPathAtOffsetZeroSkipsRead() throws {
        let mock = MockBackend()
        _ = mock.createFile(path: "/f", mode: 0o644)
        _ = mock.writeFile(path: "/f", data: Data("aaa".utf8))
        mock.reset()

        // Replacing from offset 0 with >= currentSize bytes must skip RMW.
        let ok = driveWriteAt(path: "/f", offset: 0,
                              data: Data("bbbb".utf8), mock: mock)
        #expect(ok)
        let didReadFile = mock.calls.contains { call in
            if case .readFile = call { return true }
            return false
        }
        #expect(didReadFile == false)
        #expect(mock.entries["/f"]?.data == Data("bbbb".utf8))
    }

    @Test func testCreateSymbolicLink() throws {
        let mock = MockBackend()
        let ok = mock.symlink(target: "../target", linkpath: "/link")
        #expect(ok)
        #expect(mock.calls == [.symlink(target: "../target", linkpath: "/link")])
        #expect(mock.entries["/link"]?.symlinkTarget == "../target")
    }

    @Test func testRenameItem() throws {
        let mock = MockBackend()
        _ = mock.createFile(path: "/a", mode: 0o644)
        mock.reset()

        let ok = driveRename(srcParent: "/", srcName: "a",
                             dstParent: "/", dstName: "b",
                             hasOverItem: false, mock: mock)
        #expect(ok)
        #expect(mock.calls == [.rename(src: "/a", dst: "/b")])
        #expect(mock.entries["/a"] == nil)
        #expect(mock.entries["/b"] != nil)
    }

    @Test func testRenameOverExistingFile() throws {
        let mock = MockBackend()
        _ = mock.createFile(path: "/a", mode: 0o644)
        _ = mock.writeFile(path: "/a", data: Data("A".utf8))
        _ = mock.createFile(path: "/b", mode: 0o644)
        _ = mock.writeFile(path: "/b", data: Data("B".utf8))
        mock.reset()

        let ok = driveRename(srcParent: "/", srcName: "a",
                             dstParent: "/", dstName: "b",
                             hasOverItem: true, mock: mock)
        #expect(ok)

        // Filter to mutating ops — overItem requires unlink-then-rename.
        let ops = mock.calls.filter {
            if case .stat = $0 { return false }
            return true
        }
        #expect(ops == [.unlink(path: "/b"), .rename(src: "/a", dst: "/b")])
        #expect(mock.entries["/b"]?.data == Data("A".utf8))
    }

    @Test func testChownNilLeavesUnchanged() throws {
        let mock = MockBackend()
        _ = mock.createFile(path: "/x", mode: 0o644)
        _ = mock.chown(path: "/x", uid: 100, gid: 200)
        // Now bump only gid; uid should stay at 100.
        _ = mock.chown(path: "/x", uid: nil, gid: 300)
        #expect(mock.entries["/x"]?.uid == 100)
        #expect(mock.entries["/x"]?.gid == 300)
    }

    @Test func testFlushIsRecorded() throws {
        let mock = MockBackend()
        #expect(mock.flush())
        #expect(mock.calls == [.flush])
    }

    // MARK: - Deferred journal replay (loadResource → activate workaround)

    @Test func testReplayCalledOnActivateWhenRequired() throws {
        // RW mount path: loadResource used the lazy entry point, so the
        // first activate must drive the deferred replay.
        let mock = MockBackend()
        let ok = driveActivate(requiresJournalReplay: true, mock: mock)
        #expect(ok)
        #expect(mock.replayJournalCallCount == 1)
        #expect(mock.calls == [.replayJournalIfDirty])
    }

    @Test func testReplayNotCalledOnActivateWhenRO() throws {
        // RO fallback path: loadResource used fs_ext4_mount_with_callbacks
        // (no journal touched), so activate must NOT call replay.
        let mock = MockBackend()
        let ok = driveActivate(requiresJournalReplay: false, mock: mock)
        #expect(ok)
        #expect(mock.replayJournalCallCount == 0)
        #expect(mock.calls.isEmpty)
    }

    @Test func testReplayFailureDoesNotThrowFromActivate() throws {
        // Replay failure must not bring the mount down — the volume is
        // still usable read-only and the host app can surface the
        // failure to the user separately.
        let mock = MockBackend()
        mock.replayJournalReturn = false
        let ok = driveActivate(requiresJournalReplay: true, mock: mock)
        #expect(ok)
        #expect(mock.replayJournalCallCount == 1)
    }
}
