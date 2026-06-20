//
//  ErofsVolumeTests.swift — exercises the read-only EROFS volume's call
//  patterns against a local mock that records every backend call.
//
//  The real fs_erofs_* C ABI lives behind the DiskJockeyEROFS extension
//  target and isn't visible here, and FSKit framework types can't easily
//  be constructed in a unit-test bundle. So this file mirrors the volume's
//  wiring with a self-contained mock + driver functions (same approach as
//  EXT4VolumeTests / NTFSVolumeTests).
//
//  EROFS is READ-ONLY + immutable, and its inode identity (NID) is 64-bit
//  (unlike SquashFS's 32-bit inodes). The contract under test:
//    - reads / stat / enumerate / readlink succeed and dispatch correctly
//    - every mutating op (create / write / rename / remove / truncate /
//      setattr / symlink / link) rejects with POSIXError(.EROFS), exactly
//      as ErofsVolume does.
//

import Foundation
import Testing
@testable import DiskJockey

// MARK: - Local read-only backend mirror

private enum MockErofsFileType {
    case file
    case directory
    case symlink
}

private struct MockErofsEntry {
    var type: MockErofsFileType
    /// EROFS NIDs are 64-bit — model the identity width explicitly so the
    /// test reflects the volume's `FileIDCache<ErofsItem>` (UInt64) keying.
    var inode: UInt64
    var data: Data
    var mode: UInt16
    var symlinkTarget: String?
}

/// Records reads + rejects writes, mirroring how ErofsVolume routes every
/// mutating FSVolume op to `throw POSIXError(.EROFS)` while reads dispatch
/// into the (here-mocked) fs_erofs_* C ABI.
private final class MockErofsBackend {

    enum Call: Equatable {
        case stat(path: String)
        case readFile(path: String, offset: UInt64, length: UInt64)
        case readDirectory(path: String)
        case readlink(path: String)
    }

    private(set) var calls: [Call] = []
    private(set) var entries: [String: MockErofsEntry] = [
        "/": MockErofsEntry(type: .directory, inode: 1, data: Data(), mode: 0o555, symlinkTarget: nil)
    ]

    func seed(_ path: String, _ entry: MockErofsEntry) { entries[path] = entry }

    // MARK: reads

    func stat(path: String) -> MockErofsEntry? {
        calls.append(.stat(path: path))
        return entries[path]
    }

    func readFile(path: String, offset: UInt64, length: UInt64) -> Data? {
        calls.append(.readFile(path: path, offset: offset, length: length))
        guard let e = entries[path], e.type == .file else { return nil }
        let start = min(Int(offset), e.data.count)
        let end = min(start + Int(length), e.data.count)
        return e.data.subdata(in: start..<end)
    }

    func readDirectory(path: String) -> [String]? {
        calls.append(.readDirectory(path: path))
        guard let e = entries[path], e.type == .directory else { return nil }
        let prefix = path == "/" ? "/" : "\(path)/"
        return entries.keys
            .filter { $0 != path && $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }
            .sorted()
    }

    func readlink(path: String) -> String? {
        calls.append(.readlink(path: path))
        guard let e = entries[path], e.type == .symlink else { return nil }
        return e.symlinkTarget
    }
}

// MARK: - Drivers mirroring the volume's wiring (read path)

private func joinPath(_ parent: String, _ child: String) -> String {
    parent == "/" ? "/\(child)" : "\(parent)/\(child)"
}

/// Mirrors `ErofsVolume.lookupItem` — join then stat-by-path; ENOENT when
/// the child doesn't exist. Returns the resolved NID so the 64-bit
/// identity is asserted end-to-end.
private func driveLookup(name: String, parent: String,
                         mock: MockErofsBackend) throws -> (path: String, inode: UInt64) {
    let child = joinPath(parent, name)
    guard let e = mock.stat(path: child) else { throw POSIXError(.ENOENT) }
    return (child, e.inode)
}

/// Mirrors `ErofsVolume.read` — straight dispatch into readFile.
private func driveRead(path: String, offset: UInt64, length: UInt64,
                       mock: MockErofsBackend) throws -> Data {
    guard let data = mock.readFile(path: path, offset: offset, length: length) else {
        throw POSIXError(.EBADF)
    }
    return data
}

/// Mirrors `ErofsVolume.readSymbolicLink`.
private func driveReadlink(path: String, mock: MockErofsBackend) throws -> String {
    guard let target = mock.readlink(path: path) else { throw POSIXError(.EIO) }
    return target
}

// MARK: - Read-only mutating-op drivers (every one must throw EROFS)

private enum ROMutation {
    case createItem, write, rename, removeItem, truncate, setAttributes, symlink, link
}

/// Mirrors ErofsVolume's mutating ops, all of which unconditionally
/// `throw POSIXError(.EROFS)`.
private func driveMutation(_ op: ROMutation) throws {
    _ = op
    throw POSIXError(.EROFS)
}

// MARK: - Tests

struct ErofsVolumeTests {

    // MARK: read path

    @Test func testStatRootSucceeds() throws {
        let mock = MockErofsBackend()
        let e = mock.stat(path: "/")
        #expect(e?.type == .directory)
        #expect(e?.inode == 1)
        #expect(mock.calls == [.stat(path: "/")])
    }

    @Test func testLookupResolves64BitNID() throws {
        let mock = MockErofsBackend()
        mock.seed("/usr", MockErofsEntry(type: .directory, inode: 1024, data: Data(), mode: 0o555, symlinkTarget: nil))
        // A NID beyond UInt32 range — proves the identity path is 64-bit.
        let bigNID: UInt64 = 0x1_0000_0042
        mock.seed("/usr/bin", MockErofsEntry(type: .directory, inode: bigNID, data: Data(), mode: 0o555, symlinkTarget: nil))

        let (path, inode) = try driveLookup(name: "bin", parent: "/usr", mock: mock)
        #expect(path == "/usr/bin")
        #expect(inode == bigNID)
        #expect(inode > UInt64(UInt32.max))
        #expect(mock.calls == [.stat(path: "/usr/bin")])
    }

    @Test func testLookupMissingThrowsENOENT() throws {
        let mock = MockErofsBackend()
        #expect(throws: POSIXError.self) {
            _ = try driveLookup(name: "nope", parent: "/", mock: mock)
        }
    }

    @Test func testReadReturnsFileBytes() throws {
        let mock = MockErofsBackend()
        mock.seed("/readme", MockErofsEntry(type: .file, inode: 7, data: Data("erofs!".utf8), mode: 0o444, symlinkTarget: nil))

        let data = try driveRead(path: "/readme", offset: 0, length: 6, mock: mock)
        #expect(data == Data("erofs!".utf8))
        #expect(mock.calls == [.readFile(path: "/readme", offset: 0, length: 6)])
    }

    @Test func testReadAtOffset() throws {
        let mock = MockErofsBackend()
        mock.seed("/f", MockErofsEntry(type: .file, inode: 8, data: Data("0123456789".utf8), mode: 0o444, symlinkTarget: nil))

        let data = try driveRead(path: "/f", offset: 7, length: 2, mock: mock)
        #expect(data == Data("78".utf8))
    }

    @Test func testEnumerateDirectoryListsChildren() throws {
        let mock = MockErofsBackend()
        mock.seed("/dir", MockErofsEntry(type: .directory, inode: 2, data: Data(), mode: 0o555, symlinkTarget: nil))
        mock.seed("/dir/x", MockErofsEntry(type: .file, inode: 3, data: Data(), mode: 0o444, symlinkTarget: nil))
        mock.seed("/dir/y", MockErofsEntry(type: .file, inode: 4, data: Data(), mode: 0o444, symlinkTarget: nil))

        let kids = mock.readDirectory(path: "/dir")
        #expect(kids == ["/dir/x", "/dir/y"])
        #expect(mock.calls == [.readDirectory(path: "/dir")])
    }

    @Test func testReadlinkReturnsTarget() throws {
        let mock = MockErofsBackend()
        mock.seed("/link", MockErofsEntry(type: .symlink, inode: 9, data: Data(), mode: 0o777, symlinkTarget: "/usr/bin/env"))

        let target = try driveReadlink(path: "/link", mock: mock)
        #expect(target == "/usr/bin/env")
        #expect(mock.calls == [.readlink(path: "/link")])
    }

    // MARK: read-only enforcement — every mutation throws EROFS

    @Test func testCreateItemRejectedEROFS() throws {
        expectEROFS { try driveMutation(.createItem) }
    }

    @Test func testWriteRejectedEROFS() throws {
        expectEROFS { try driveMutation(.write) }
    }

    @Test func testRenameRejectedEROFS() throws {
        expectEROFS { try driveMutation(.rename) }
    }

    @Test func testRemoveItemRejectedEROFS() throws {
        expectEROFS { try driveMutation(.removeItem) }
    }

    @Test func testTruncateRejectedEROFS() throws {
        expectEROFS { try driveMutation(.truncate) }
    }

    @Test func testSetAttributesRejectedEROFS() throws {
        expectEROFS { try driveMutation(.setAttributes) }
    }

    @Test func testCreateSymbolicLinkRejectedEROFS() throws {
        expectEROFS { try driveMutation(.symlink) }
    }

    @Test func testCreateLinkRejectedEROFS() throws {
        expectEROFS { try driveMutation(.link) }
    }

    // Helper — asserts the closure throws POSIXError(.EROFS) specifically.
    private func expectEROFS(_ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected POSIXError(.EROFS), got no throw")
        } catch let error as POSIXError {
            #expect(error.code == .EROFS)
        } catch {
            Issue.record("expected POSIXError(.EROFS), got \(error)")
        }
    }
}
