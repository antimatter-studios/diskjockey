//
//  NTFSVolumeTests.swift — exercises the NTFS volume's call patterns
//  against a local mock that records every backend invocation.
//
//  The real NTFS bridge entry points (fs_ntfs_create_file_h,
//  fs_ntfs_mkdir_h, fs_ntfs_rename_h, fs_ntfs_truncate_h,
//  fs_ntfs_set_times_h, etc.) live behind the DiskJockeyNTFS extension
//  target's C ABI and aren't visible here. This file mirrors the
//  call shapes — parent_path + basename for create/mkdir, basename-
//  only same-directory rename, shrink-only truncate, FILETIME-based
//  set_times — so we can validate the volume's wiring without dragging
//  in FSKit framework types or the Rust bridge.
//

import Foundation
import Testing
@testable import DiskJockey

// MARK: - Local protocol mirror

private enum MockFileType {
    case file
    case directory
    case symlink
    case junction
}

private struct MockEntry {
    var type: MockFileType
    var data: Data
    var mftNumber: Int64
    var modifyTime: Int64
    var accessTime: Int64
    var creationTime: Int64
    var changeTime: Int64
}

private final class MockNTFSBackend {

    enum Call: Equatable {
        case createFile(parent: String, basename: String)
        case mkdir(parent: String, basename: String)
        case writeFile(path: String, length: UInt64)
        case unlink(path: String)
        case rmdir(path: String)
        case rename(oldPath: String, newBasename: String)
        case truncate(path: String, size: UInt64)
        case setTimes(path: String,
                      modify: Int64?,
                      access: Int64?,
                      creation: Int64?,
                      change: Int64?)
        case stat(path: String)
        case readFile(path: String, offset: UInt64, length: UInt64)
    }

    private(set) var calls: [Call] = []
    private(set) var entries: [String: MockEntry] = [
        "/": MockEntry(type: .directory, data: Data(), mftNumber: 5,
                       modifyTime: 0, accessTime: 0, creationTime: 0, changeTime: 0)
    ]
    private var lastErrno_: Int32 = 0
    private var nextMft: Int64 = 100

    func reset() {
        calls.removeAll()
        lastErrno_ = 0
    }

    func setLastErrno(_ e: Int32) { lastErrno_ = e }
    func lastErrno() -> Int32 { lastErrno_ }

    private func joinPath(_ parent: String, _ child: String) -> String {
        return parent == "/" ? "/\(child)" : "\(parent)/\(child)"
    }

    private func allocMft() -> Int64 {
        let n = nextMft
        nextMft += 1
        return n
    }

    func stat(path: String) -> MockEntry? {
        calls.append(.stat(path: path))
        if let e = entries[path] { return e }
        lastErrno_ = ENOENT
        return nil
    }

    func createFile(parent: String, basename: String) -> Int64 {
        calls.append(.createFile(parent: parent, basename: basename))
        let path = joinPath(parent, basename)
        guard entries[path] == nil else { lastErrno_ = EEXIST; return -1 }
        let mft = allocMft()
        entries[path] = MockEntry(type: .file, data: Data(), mftNumber: mft,
                                  modifyTime: 0, accessTime: 0,
                                  creationTime: 0, changeTime: 0)
        return mft
    }

    func mkdir(parent: String, basename: String) -> Int64 {
        calls.append(.mkdir(parent: parent, basename: basename))
        let path = joinPath(parent, basename)
        guard entries[path] == nil else { lastErrno_ = EEXIST; return -1 }
        let mft = allocMft()
        entries[path] = MockEntry(type: .directory, data: Data(), mftNumber: mft,
                                  modifyTime: 0, accessTime: 0,
                                  creationTime: 0, changeTime: 0)
        return mft
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

    func rmdir(path: String) -> Bool {
        calls.append(.rmdir(path: path))
        guard let e = entries[path] else { lastErrno_ = ENOENT; return false }
        guard e.type == .directory else { lastErrno_ = ENOTDIR; return false }
        entries.removeValue(forKey: path)
        return true
    }

    /// Basename-only same-directory rename — mirrors `fs_ntfs_rename_h`.
    func rename(oldPath: String, newBasename: String) -> Bool {
        calls.append(.rename(oldPath: oldPath, newBasename: newBasename))
        guard let e = entries[oldPath] else { lastErrno_ = ENOENT; return false }
        let parent: String
        if let slash = oldPath.lastIndex(of: "/") {
            parent = oldPath.startIndex == slash ? "/" : String(oldPath[..<slash])
        } else {
            parent = "/"
        }
        let newPath = joinPath(parent, newBasename)
        guard entries[newPath] == nil else { lastErrno_ = EEXIST; return false }
        entries.removeValue(forKey: oldPath)
        entries[newPath] = e
        return true
    }

    /// Shrink-only truncate — mirrors the Rust crate's current API.
    /// Returns false + ENOTSUP for grow attempts.
    func truncate(path: String, size: UInt64) -> Bool {
        calls.append(.truncate(path: path, size: size))
        guard var e = entries[path], e.type == .file else {
            lastErrno_ = ENOENT
            return false
        }
        if size > UInt64(e.data.count) {
            lastErrno_ = ENOTSUP
            return false
        }
        e.data = e.data.prefix(Int(size))
        entries[path] = e
        return true
    }

    func setTimes(path: String,
                  modify: Int64?,
                  access: Int64?,
                  creation: Int64?,
                  change: Int64?) -> Bool {
        calls.append(.setTimes(path: path, modify: modify, access: access,
                               creation: creation, change: change))
        guard var e = entries[path] else { lastErrno_ = ENOENT; return false }
        if let m = modify { e.modifyTime = m }
        if let a = access { e.accessTime = a }
        if let c = creation { e.creationTime = c }
        if let ch = change { e.changeTime = ch }
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
}

// MARK: - Drivers — pure logic helpers that mirror the volume's wiring

/// Reproduces the volume's path-join behaviour so we can test the call
/// pattern without dragging in FSKit.
private func joinPath(_ parent: String, _ child: String) -> String {
    return parent == "/" ? "/\(child)" : "\(parent)/\(child)"
}

/// Drives MockNTFSBackend the same way NTFSVolume.createItem does for
/// files — `fs_ntfs_create_file_h(parent_path, basename)`. Returns the
/// allocated MFT record number plus a success flag.
private func driveCreateItemFile(name: String, parent: String,
                                 mock: MockNTFSBackend) -> (Int64, Bool) {
    let mft = mock.createFile(parent: parent, basename: name)
    return (mft, mft >= 0)
}

/// Drives MockNTFSBackend the same way NTFSVolume.createItem does for
/// directories — `fs_ntfs_mkdir_h(parent_path, basename)`.
private func driveCreateItemDirectory(name: String, parent: String,
                                      mock: MockNTFSBackend) -> (Int64, Bool) {
    let mft = mock.mkdir(parent: parent, basename: name)
    return (mft, mft >= 0)
}

/// Drives MockNTFSBackend the same way NTFSVolume.removeItem does —
/// stat first, then dispatch to rmdir (dir/junction) or unlink
/// (file/symlink) based on the entry type.
private func driveRemoveItem(name: String, parent: String,
                             mock: MockNTFSBackend) -> Bool {
    let child = joinPath(parent, name)
    guard let entry = mock.stat(path: child) else { return false }
    switch entry.type {
    case .directory, .junction: return mock.rmdir(path: child)
    case .file, .symlink:        return mock.unlink(path: child)
    }
}

/// Drives MockNTFSBackend the same way NTFSVolume.write(contents:to:at:)
/// does — fast path at offset 0 with full-file replace, slow path
/// read-modify-write through the whole-file replace API.
private func driveWriteAt(path: String, offset: UInt64, data: Data,
                          mock: MockNTFSBackend) -> Bool {
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

/// Drives MockNTFSBackend the same way NTFSVolume.renameItem does for
/// the same-directory case, including the "remove existing destination
/// first" branch when overItem is set. Cross-directory rename is NOT
/// modeled — NTFSVolume throws ENOTSUP for that case at the moment.
private func driveRename(srcParent: String, srcName: String,
                         dstName: String,
                         hasOverItem: Bool,
                         mock: MockNTFSBackend) -> Bool {
    let src = joinPath(srcParent, srcName)
    let dst = joinPath(srcParent, dstName)
    if hasOverItem {
        if let dstEntry = mock.stat(path: dst) {
            let removed: Bool
            switch dstEntry.type {
            case .directory, .junction: removed = mock.rmdir(path: dst)
            case .file, .symlink:        removed = mock.unlink(path: dst)
            }
            if !removed { return false }
        }
    }
    return mock.rename(oldPath: src, newBasename: dstName)
}

/// Mirrors NTFSVolume's AppleDouble swallow path: any name beginning
/// with `._` returns success without touching the backend. The volume's
/// caller still gets a success result; the backend records nothing.
private func driveAppleDoubleCreate(name: String, parent: String,
                                    mock: MockNTFSBackend) -> Bool {
    if name.hasPrefix("._") { return true }
    return mock.createFile(parent: parent, basename: name) >= 0
}

/// Mirrors NTFSVolume's AppleDouble write swallow: writes to a `._*`
/// path return the input length without ever invoking writeFile.
private func driveAppleDoubleWrite(path: String, data: Data,
                                   mock: MockNTFSBackend) -> Int {
    let basename: String
    if let slash = path.lastIndex(of: "/") {
        basename = String(path[path.index(after: slash)...])
    } else {
        basename = path
    }
    if basename.hasPrefix("._") { return data.count }
    return Int(mock.writeFile(path: path, data: data))
}

// MARK: - Tests

struct NTFSVolumeTests {

    @Test func testCreateFileSucceeds() throws {
        let mock = MockNTFSBackend()
        let (mft, ok) = driveCreateItemFile(name: "foo.txt", parent: "/",
                                            mock: mock)
        #expect(ok)
        #expect(mft > 0)
        #expect(mock.calls == [.createFile(parent: "/", basename: "foo.txt")])
        #expect(mock.entries["/foo.txt"] != nil)
        #expect(mock.entries["/foo.txt"]?.mftNumber == mft)
    }

    @Test func testCreateFileInSubdirectory() throws {
        let mock = MockNTFSBackend()
        _ = mock.mkdir(parent: "/", basename: "sub")
        mock.reset()

        let (mft, ok) = driveCreateItemFile(name: "bar", parent: "/sub",
                                            mock: mock)
        #expect(ok)
        #expect(mft > 0)
        #expect(mock.calls == [.createFile(parent: "/sub", basename: "bar")])
        #expect(mock.entries["/sub/bar"] != nil)
    }

    @Test func testCreateDirectory() throws {
        let mock = MockNTFSBackend()
        let (mft, ok) = driveCreateItemDirectory(name: "newdir", parent: "/",
                                                 mock: mock)
        #expect(ok)
        #expect(mft > 0)
        #expect(mock.calls == [.mkdir(parent: "/", basename: "newdir")])
        #expect(mock.entries["/newdir"]?.type == .directory)
    }

    @Test func testRemoveItemDispatchesByType() throws {
        let mock = MockNTFSBackend()
        _ = mock.createFile(parent: "/", basename: "file")
        _ = mock.mkdir(parent: "/", basename: "dir")
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
        let mock = MockNTFSBackend()
        _ = mock.createFile(parent: "/", basename: "greeting")
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
        let mock = MockNTFSBackend()
        _ = mock.createFile(parent: "/", basename: "f")
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

    @Test func testRenameItem() throws {
        let mock = MockNTFSBackend()
        _ = mock.createFile(parent: "/", basename: "a")
        mock.reset()

        let ok = driveRename(srcParent: "/", srcName: "a",
                             dstName: "b",
                             hasOverItem: false, mock: mock)
        #expect(ok)
        #expect(mock.calls == [.rename(oldPath: "/a", newBasename: "b")])
        #expect(mock.entries["/a"] == nil)
        #expect(mock.entries["/b"] != nil)
    }

    @Test func testRenameOverExistingFile() throws {
        let mock = MockNTFSBackend()
        _ = mock.createFile(parent: "/", basename: "a")
        _ = mock.writeFile(path: "/a", data: Data("A".utf8))
        _ = mock.createFile(parent: "/", basename: "b")
        _ = mock.writeFile(path: "/b", data: Data("B".utf8))
        mock.reset()

        let ok = driveRename(srcParent: "/", srcName: "a",
                             dstName: "b",
                             hasOverItem: true, mock: mock)
        #expect(ok)

        // Filter to mutating ops — overItem requires unlink-then-rename.
        let ops = mock.calls.filter {
            if case .stat = $0 { return false }
            return true
        }
        #expect(ops == [.unlink(path: "/b"),
                        .rename(oldPath: "/a", newBasename: "b")])
        #expect(mock.entries["/b"]?.data == Data("A".utf8))
    }

    @Test func testTruncateShrinkSucceeds() throws {
        let mock = MockNTFSBackend()
        _ = mock.createFile(parent: "/", basename: "big")
        _ = mock.writeFile(path: "/big", data: Data(repeating: 0x41, count: 100))
        mock.reset()

        let ok = mock.truncate(path: "/big", size: 50)
        #expect(ok)
        #expect(mock.calls == [.truncate(path: "/big", size: 50)])
        #expect(mock.entries["/big"]?.data.count == 50)
    }

    @Test func testTruncateGrowFails() throws {
        let mock = MockNTFSBackend()
        _ = mock.createFile(parent: "/", basename: "small")
        _ = mock.writeFile(path: "/small", data: Data(repeating: 0x41, count: 50))
        mock.reset()

        let ok = mock.truncate(path: "/small", size: 100)
        #expect(ok == false)
        #expect(mock.lastErrno() == ENOTSUP)
        #expect(mock.entries["/small"]?.data.count == 50)
    }

    @Test func testAppleDoubleCreateSwallowed() throws {
        let mock = MockNTFSBackend()
        let ok = driveAppleDoubleCreate(name: "._foo", parent: "/", mock: mock)
        #expect(ok)
        // The volume swallows AppleDouble creates — backend must see nothing.
        #expect(mock.calls.isEmpty)
        #expect(mock.entries["/._foo"] == nil)
    }

    @Test func testAppleDoubleWriteSwallowed() throws {
        let mock = MockNTFSBackend()
        let payload = Data("metadata".utf8)
        let n = driveAppleDoubleWrite(path: "/._foo", data: payload, mock: mock)
        #expect(n == payload.count)
        #expect(mock.calls.isEmpty)
    }

    @Test func testSetTimesRecorded() throws {
        let mock = MockNTFSBackend()
        _ = mock.createFile(parent: "/", basename: "t.txt")
        mock.reset()

        // FILETIME values: 100ns ticks since 1601-01-01 UTC. Use
        // representative non-zero values so we can read them back.
        let modify: Int64 = 132_000_000_000_000_000
        let access: Int64 = 132_000_000_000_000_001
        let creation: Int64 = 132_000_000_000_000_002
        let change: Int64 = 132_000_000_000_000_003

        let ok = mock.setTimes(path: "/t.txt",
                               modify: modify, access: access,
                               creation: creation, change: change)
        #expect(ok)
        #expect(mock.calls == [.setTimes(path: "/t.txt",
                                         modify: modify,
                                         access: access,
                                         creation: creation,
                                         change: change)])
        #expect(mock.entries["/t.txt"]?.modifyTime == modify)
        #expect(mock.entries["/t.txt"]?.accessTime == access)
        #expect(mock.entries["/t.txt"]?.creationTime == creation)
        #expect(mock.entries["/t.txt"]?.changeTime == change)
    }
}
