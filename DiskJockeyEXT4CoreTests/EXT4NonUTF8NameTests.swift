//
//  EXT4NonUTF8NameTests.swift — a name FSKit hands the ext4 volume reaches
//  the backend as the bytes it was given (diskjockey#219).
//
//  An ext4 name is a byte string with no encoding rule. FSKit's FSFileName
//  carries such a name as bytes (`data`), and its `string` is nil when they
//  are not UTF-8. The volume built every child path from `name.string`, so a
//  name that is not UTF-8 was refused with EINVAL before it could reach the
//  backend — a file Finder had just listed could not be looked up, removed
//  or renamed.
//
//  Host-free: the real EXT4Volume over a backend that records what it is
//  asked for.
//

import Foundation
import FSKit
import Testing
@testable import DiskJockeyEXT4Core
@testable import DiskJockeyLibrary

private let slash = UInt8(ascii: "/")
private let cafE9: [UInt8] = Array("caf".utf8) + [0xE9] + Array(".txt".utf8)
private let cafEA: [UInt8] = Array("caf".utf8) + [0xEA] + Array(".txt".utf8)

private func makeVolume(_ backend: FileSystemBackend) -> EXT4Volume {
    EXT4Volume(volumeID: FSVolume.Identifier(uuid: UUID()),
               volumeName: FSFileName(string: "test"),
               backend: backend,
               requiresJournalReplay: false,
               stats: IOStatsCollector(label: "test", emit: { _ in }),
               opLock: OperationLock())
}

@Suite("EXT4Volume names that are not UTF-8")
struct EXT4NonUTF8NameTests {

    @Test func aLookupAsksTheBackendForTheNamesBytes() async throws {
        let backend = RecordingBackend()
        let volume = makeVolume(backend)
        let root = volume.item(forID: 2, path: "/", parentInode: nil)
        let (found, _) = try await volume.lookupItem(
            named: FSFileName(data: Data(cafE9)), inDirectory: root)
        #expect(backend.statted == [[slash] + cafE9])
        #expect((found as? EXT4Item)?.volumePath.bytes == [slash] + cafE9)
    }

    @Test func twoNamesDifferingInAnInvalidByteAreLookedUpAsTwoPaths() async throws {
        let backend = RecordingBackend()
        let volume = makeVolume(backend)
        let root = volume.item(forID: 2, path: "/", parentInode: nil)
        _ = try await volume.lookupItem(named: FSFileName(data: Data(cafE9)), inDirectory: root)
        _ = try await volume.lookupItem(named: FSFileName(data: Data(cafEA)), inDirectory: root)
        #expect(backend.statted == [[slash] + cafE9, [slash] + cafEA])
    }

    @Test func aRemoveUnlinksTheNamesBytes() async throws {
        let backend = RecordingBackend()
        let volume = makeVolume(backend)
        let root = volume.item(forID: 2, path: "/", parentInode: nil)
        let (file, _) = try await volume.lookupItem(
            named: FSFileName(data: Data(cafE9)), inDirectory: root)
        try await volume.removeItem(file, named: FSFileName(data: Data(cafE9)), fromDirectory: root)
        #expect(backend.unlinked == [[slash] + cafE9])
    }

    @Test func aRenameMovesBetweenTheNamesBytes() async throws {
        let backend = RecordingBackend()
        let volume = makeVolume(backend)
        let root = volume.item(forID: 2, path: "/", parentInode: nil)
        let (file, _) = try await volume.lookupItem(
            named: FSFileName(data: Data(cafE9)), inDirectory: root)
        _ = try await volume.renameItem(
            file, inDirectory: root, named: FSFileName(data: Data(cafE9)),
            to: FSFileName(data: Data(cafEA)), inDirectory: root, overItem: nil)
        #expect(backend.renamed.count == 1)
        #expect(backend.renamed.first?.0 == [slash] + cafE9)
        #expect(backend.renamed.first?.1 == [slash] + cafEA)
    }
}

/// Answers every stat with a regular file and records the paths it was
/// handed, as bytes.
private final class RecordingBackend: FileSystemBackend {
    var statted: [[UInt8]] = []
    var unlinked: [[UInt8]] = []
    var renamed: [([UInt8], [UInt8])] = []

    func lastErrno() -> Int32 { 0 }
    func lastErrorMessage() -> String { "(stub)" }

    func stat(path: String) -> BackendFileAttributes? {
        statted.append(Array(path.utf8))
        return BackendFileAttributes(fileID: 12, fileType: .file, mode: 0o644, uid: 0, gid: 0,
                                     size: 0, linkCount: 1, atime: 0, mtime: 0, ctime: 0, crtime: 0)
    }
    func unlink(path: String) -> Bool { unlinked.append(Array(path.utf8)); return true }
    func rename(src: String, dst: String) -> Bool {
        renamed.append((Array(src.utf8), Array(dst.utf8))); return true
    }

    func volumeInfo() -> BackendVolumeInfo { unreachable() }
    func shutdown() {}
    func readDirectory(path: String) -> [BackendDirectoryEntry]? { unreachable() }
    func readFile(path: String, offset: UInt64, length: UInt64,
                  buffer: UnsafeMutableRawPointer) -> Int64 { unreachable() }
    func readSymlink(path: String) -> String? { unreachable() }
    func createFile(path: String, mode: UInt16) -> Bool { unreachable() }
    func writeFile(path: String, data: UnsafeRawPointer, length: UInt64) -> Int64 { unreachable() }
    func pwrite(path: String, offset: UInt64,
                data: UnsafeRawPointer, length: UInt64) -> Int64 { unreachable() }
    func mkdir(path: String, mode: UInt16) -> Bool { unreachable() }
    func rmdir(path: String) -> Bool { unreachable() }
    func truncate(path: String, size: UInt64) -> Bool { unreachable() }
    func chmod(path: String, mode: UInt16) -> Bool { unreachable() }
    func chown(path: String, uid: UInt32?, gid: UInt32?) -> Bool { unreachable() }
    func symlink(target: String, linkpath: String) -> Bool { unreachable() }
    func link(src: String, dst: String) -> Bool { unreachable() }
    func utimens(path: String, atime: timespec?, mtime: timespec?) -> Bool { unreachable() }
    func flush() -> Bool { unreachable() }

    private func unreachable(_ function: String = #function) -> Never {
        fatalError("RecordingBackend.\(function) was called; these tests do not reach it")
    }
}
