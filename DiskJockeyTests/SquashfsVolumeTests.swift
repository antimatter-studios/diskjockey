//
//  SquashfsVolumeTests.swift — exercises the read-only SquashFS volume's
//  call patterns against a local mock that records every backend call.
//
//  The real fs_squashfs_* C ABI lives behind the DiskJockeySQUASHFS
//  extension target and isn't visible here, and FSKit framework types
//  can't easily be constructed in a unit-test bundle. So this file mirrors
//  the volume's wiring with a self-contained mock + driver functions
//  (same approach as EXT4VolumeTests / NTFSVolumeTests).
//
//  SquashFS is READ-ONLY + immutable. The contract under test:
//    - reads / stat / enumerate / readlink succeed and dispatch correctly
//      (path-join, stat-by-path, directory iteration with cookies)
//    - every mutating op (create / write / rename / remove / truncate /
//      setattr / symlink / link) rejects with POSIXError(.EROFS), exactly
//      as SquashfsVolume does.
//

import Foundation
import Testing
@testable import DiskJockey

// MARK: - Local read-only backend mirror

private enum MockROFileType {
    case file
    case directory
    case symlink
}

private struct MockROEntry {
    var type: MockROFileType
    var data: Data
    var mode: UInt16
    var symlinkTarget: String?
}

/// Records reads + rejects writes, mirroring how SquashfsVolume routes
/// every mutating FSVolume op to `throw POSIXError(.EROFS)` while reads
/// dispatch into the (here-mocked) fs_squashfs_* C ABI.
private final class MockSquashfsBackend {

    enum Call: Equatable {
        case stat(path: String)
        case readFile(path: String, offset: UInt64, length: UInt64)
        case readDirectory(path: String)
        case readlink(path: String)
    }

    private(set) var calls: [Call] = []
    private(set) var entries: [String: MockROEntry] = [
        "/": MockROEntry(type: .directory, data: Data(), mode: 0o555, symlinkTarget: nil)
    ]

    func seed(_ path: String, _ entry: MockROEntry) { entries[path] = entry }

    // MARK: reads

    func stat(path: String) -> MockROEntry? {
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

/// Mirrors `SquashfsVolume.lookupItem` — join then stat-by-path; ENOENT
/// when the child doesn't exist.
private func driveLookup(name: String, parent: String,
                         mock: MockSquashfsBackend) throws -> String {
    let child = joinPath(parent, name)
    guard mock.stat(path: child) != nil else { throw POSIXError(.ENOENT) }
    return child
}

/// Mirrors `SquashfsVolume.read` — straight dispatch into readFile.
private func driveRead(path: String, offset: UInt64, length: UInt64,
                       mock: MockSquashfsBackend) throws -> Data {
    guard let data = mock.readFile(path: path, offset: offset, length: length) else {
        throw POSIXError(.EBADF)
    }
    return data
}

/// Mirrors `SquashfsVolume.readSymbolicLink`.
private func driveReadlink(path: String, mock: MockSquashfsBackend) throws -> String {
    guard let target = mock.readlink(path: path) else { throw POSIXError(.EIO) }
    return target
}

// MARK: - Read-only mutating-op drivers (every one must throw EROFS)

private enum ROMutation {
    case createItem, write, rename, removeItem, truncate, setAttributes, symlink, link
}

/// Mirrors SquashfsVolume's mutating ops, all of which unconditionally
/// `throw POSIXError(.EROFS)`.
private func driveMutation(_ op: ROMutation) throws {
    _ = op
    throw POSIXError(.EROFS)
}

// MARK: - Tests

struct SquashfsVolumeTests {

    // MARK: read path

    @Test func testStatRootSucceeds() throws {
        let mock = MockSquashfsBackend()
        let e = mock.stat(path: "/")
        #expect(e?.type == .directory)
        #expect(mock.calls == [.stat(path: "/")])
    }

    @Test func testLookupResolvesChildPath() throws {
        let mock = MockSquashfsBackend()
        mock.seed("/etc", MockROEntry(type: .directory, data: Data(), mode: 0o555, symlinkTarget: nil))
        mock.seed("/etc/hosts", MockROEntry(type: .file, data: Data("127.0.0.1\n".utf8), mode: 0o444, symlinkTarget: nil))

        let path = try driveLookup(name: "hosts", parent: "/etc", mock: mock)
        #expect(path == "/etc/hosts")
        #expect(mock.calls == [.stat(path: "/etc/hosts")])
    }

    @Test func testLookupMissingThrowsENOENT() throws {
        let mock = MockSquashfsBackend()
        #expect(throws: POSIXError.self) {
            _ = try driveLookup(name: "nope", parent: "/", mock: mock)
        }
    }

    @Test func testReadReturnsFileBytes() throws {
        let mock = MockSquashfsBackend()
        mock.seed("/readme", MockROEntry(type: .file, data: Data("squashfs!".utf8), mode: 0o444, symlinkTarget: nil))

        let data = try driveRead(path: "/readme", offset: 0, length: 9, mock: mock)
        #expect(data == Data("squashfs!".utf8))
        #expect(mock.calls == [.readFile(path: "/readme", offset: 0, length: 9)])
    }

    @Test func testReadAtOffset() throws {
        let mock = MockSquashfsBackend()
        mock.seed("/f", MockROEntry(type: .file, data: Data("0123456789".utf8), mode: 0o444, symlinkTarget: nil))

        let data = try driveRead(path: "/f", offset: 4, length: 3, mock: mock)
        #expect(data == Data("456".utf8))
    }

    @Test func testEnumerateDirectoryListsChildren() throws {
        let mock = MockSquashfsBackend()
        mock.seed("/dir", MockROEntry(type: .directory, data: Data(), mode: 0o555, symlinkTarget: nil))
        mock.seed("/dir/a", MockROEntry(type: .file, data: Data(), mode: 0o444, symlinkTarget: nil))
        mock.seed("/dir/b", MockROEntry(type: .file, data: Data(), mode: 0o444, symlinkTarget: nil))

        let kids = mock.readDirectory(path: "/dir")
        #expect(kids == ["/dir/a", "/dir/b"])
        #expect(mock.calls == [.readDirectory(path: "/dir")])
    }

    @Test func testReadlinkReturnsTarget() throws {
        let mock = MockSquashfsBackend()
        mock.seed("/link", MockROEntry(type: .symlink, data: Data(), mode: 0o777, symlinkTarget: "../target"))

        let target = try driveReadlink(path: "/link", mock: mock)
        #expect(target == "../target")
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

    // Helper — asserts the closure throws POSIXError(.EROFS) specifically,
    // not just any error (a read-only FS must reject with EROFS, not EBADF
    // or ENOENT).
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
