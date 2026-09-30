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
//  The volume is byte-exact now; what a backend's driver can be handed is
//  the backend's to declare (`pathEncoding`). The cases below run both
//  ways: a byte-exact backend gets the original bytes, and a UTF-8 one is
//  never handed a name that is not UTF-8.
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

    @Test func aSymlinkTargetThatIsNotUTF8ComesBackAsItsBytes() async throws {
        let backend = RecordingBackend()
        let target = Array("../".utf8) + cafE9
        backend.linkTarget = target
        let volume = makeVolume(backend)
        let root = volume.item(forID: 2, path: "/", parentInode: nil)
        let (link, _) = try await volume.lookupItem(
            named: FSFileName(data: Data(Array("l".utf8))), inDirectory: root)
        let got = try await volume.readSymbolicLink(link)
        #expect([UInt8](got.data) == target)
    }

    @Test func theAppleDoubleOfANameThatIsNotUTF8IsRecognised() {
        #expect(EXT4Volume.isAppleDouble(name: Array("._".utf8) + cafE9))
        #expect(!EXT4Volume.isAppleDouble(name: cafE9))
        #expect(EXT4Volume.isAppleDouble(path: VolumePath(bytes: [slash] + Array("._".utf8) + cafE9)))
    }

    // MARK: a driver that decodes paths as UTF-8

    /// am-fs-ext4 0.5.1 answers a path it cannot decode as the ROOT, and
    /// reports success (rust-fs-ext4#418). Handed one, a stat would
    /// describe the root and an unlink would act on it; so such a name
    /// must never reach it.
    @Test func aUTF8DriverIsNeverAskedToStatANameThatIsNotUTF8() async {
        let backend = RecordingBackend(pathEncoding: .utf8)
        let volume = makeVolume(backend)
        let root = volume.item(forID: 2, path: "/", parentInode: nil)
        await #expect(throws: POSIXError(.EILSEQ)) {
            _ = try await volume.lookupItem(named: FSFileName(data: Data(cafE9)), inDirectory: root)
        }
        #expect(backend.statted.isEmpty)
    }

    @Test func aUTF8DriverIsNeverAskedToUnlinkANameThatIsNotUTF8() async {
        let backend = RecordingBackend(pathEncoding: .utf8)
        let volume = makeVolume(backend)
        let root = volume.item(forID: 2, path: "/", parentInode: nil)
        let file = volume.item(forID: 12, path: "/x", parentInode: 2)
        await #expect(throws: POSIXError(.EILSEQ)) {
            try await volume.removeItem(file, named: FSFileName(data: Data(cafE9)), fromDirectory: root)
        }
        #expect(backend.statted.isEmpty)
        #expect(backend.unlinked.isEmpty)
    }

    @Test func aUTF8DriverStillGetsUTF8Names() async throws {
        let backend = RecordingBackend(pathEncoding: .utf8)
        let volume = makeVolume(backend)
        let root = volume.item(forID: 2, path: "/", parentInode: nil)
        let cafe = Array("caf\u{e9}.txt".utf8)
        _ = try await volume.lookupItem(named: FSFileName(data: Data(cafe)), inDirectory: root)
        #expect(backend.statted == [[slash] + cafe])
    }
}

/// Answers every stat with a regular file (a symlink when a target is
/// set) and records the paths it was handed, as bytes.
private final class RecordingBackend: FileSystemBackend {
    let pathEncoding: DriverPathEncoding
    var statted: [[UInt8]] = []
    var unlinked: [[UInt8]] = []
    var renamed: [([UInt8], [UInt8])] = []
    var linkTarget: [UInt8]?

    init(pathEncoding: DriverPathEncoding = .bytes) {
        self.pathEncoding = pathEncoding
    }

    func lastErrno() -> Int32 { 0 }
    func lastErrorMessage() -> String { "(stub)" }

    func stat(path: VolumePath) -> BackendFileAttributes? {
        statted.append(path.bytes)
        return BackendFileAttributes(fileID: 12, fileType: linkTarget == nil ? .file : .symlink,
                                     mode: 0o644, uid: 0, gid: 0, size: 0, linkCount: 1,
                                     atime: 0, mtime: 0, ctime: 0, crtime: 0)
    }
    func unlink(path: VolumePath) -> Bool { unlinked.append(path.bytes); return true }
    func rename(src: VolumePath, dst: VolumePath) -> Bool {
        renamed.append((src.bytes, dst.bytes)); return true
    }
    func readSymlink(path: VolumePath) -> [UInt8]? { linkTarget }

    func volumeInfo() -> BackendVolumeInfo { unreachable() }
    func shutdown() {}
    func readDirectory(path: VolumePath) -> [BackendDirectoryEntry]? { unreachable() }
    func readFile(path: VolumePath, offset: UInt64, length: UInt64,
                  buffer: UnsafeMutableRawPointer) -> Int64 { unreachable() }
    func createFile(path: VolumePath, mode: UInt16) -> Bool { unreachable() }
    func writeFile(path: VolumePath, data: UnsafeRawPointer, length: UInt64) -> Int64 { unreachable() }
    func pwrite(path: VolumePath, offset: UInt64,
                data: UnsafeRawPointer, length: UInt64) -> Int64 { unreachable() }
    func mkdir(path: VolumePath, mode: UInt16) -> Bool { unreachable() }
    func rmdir(path: VolumePath) -> Bool { unreachable() }
    func truncate(path: VolumePath, size: UInt64) -> Bool { unreachable() }
    func chmod(path: VolumePath, mode: UInt16) -> Bool { unreachable() }
    func chown(path: VolumePath, uid: UInt32?, gid: UInt32?) -> Bool { unreachable() }
    func symlink(target: [UInt8], linkpath: VolumePath) -> Bool { unreachable() }
    func link(src: VolumePath, dst: VolumePath) -> Bool { unreachable() }
    func utimens(path: VolumePath, atime: timespec?, mtime: timespec?) -> Bool { unreachable() }
    func flush() -> Bool { unreachable() }

    private func unreachable(_ function: String = #function) -> Never {
        fatalError("RecordingBackend.\(function) was called; these tests do not reach it")
    }
}
