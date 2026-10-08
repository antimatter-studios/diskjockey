//
//  XfsWriteTests.swift — FSKit file writes and size changes on the real
//  XfsVolume, over a driver that keeps file bytes in memory.
//
//  The stand-in answers the way fs_xfs.h says the published driver does:
//  fs_xfs_write_file rewrites bytes the file already holds and refuses
//  anything past its end with ENOTSUP, all of the range or none of it;
//  fs_xfs_truncate shortens and refuses to grow with ENOTSUP. Expected
//  values come from that header and from FSKit's contract — a write
//  answers its byte count, a failure answers the driver's errno, and a
//  set-attributes request names what it consumed (diskjockey#322).
//

import Foundation
import FSKit
import Testing
@testable import DiskJockeyXFSCore
import DiskJockeyLibrary

private final class FileDriver: XfsMountedVolumeDriver {
    var isWritable = true
    var files: [VolumePath: [UInt8]] = [:]
    var errno: Int32 = 0
    /// Every write and truncate the volume made, in order.
    private(set) var writes: [(VolumePath, UInt64, [UInt8])] = []
    private(set) var truncates: [(VolumePath, UInt64, timespec?)] = []

    func volumeInfo() -> ReadOnlyVolumeInfo? { nil }

    func stat(_ path: VolumePath) -> ReadOnlyFileAttributes? {
        guard let bytes = files[path] else { errno = ENOENT; return nil }
        return ReadOnlyFileAttributes(inode: 128, mode: 0o100644, uid: 0, gid: 0,
                                      size: UInt64(bytes.count), linkCount: 1,
                                      mtime: 0, fileType: .file)
    }

    func walkDirectory(_ path: VolumePath,
                       _ visit: (ReadOnlyDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk { .finished }

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
        writes.append((path, offset, Array(buffer)))
        guard var bytes = files[path] else { errno = ENOENT; return -1 }
        guard offset + UInt64(buffer.count) <= UInt64(bytes.count) else {
            errno = ENOTSUP
            return -1
        }
        bytes.replaceSubrange(Int(offset)..<Int(offset) + buffer.count, with: buffer)
        files[path] = bytes
        return Int64(buffer.count)
    }

    func truncate(_ path: VolumePath, to size: UInt64, modified: timespec?) -> Int32 {
        truncates.append((path, size, modified))
        guard let bytes = files[path] else { errno = ENOENT; return -1 }
        guard size <= UInt64(bytes.count) else { errno = ENOTSUP; return -1 }
        files[path] = Array(bytes.prefix(Int(size)))
        return 0
    }

    func readlink(_ path: VolumePath, _ buffer: UnsafeMutablePointer<CChar>, _ size: Int) -> Int32 { -1 }
    func lastErrno() -> Int32 { errno }
    func unmount() { isWritable = false }
}

private let filePath = VolumePath(bytes: Array("/f".utf8))

private func fixture(_ contents: String = "hello world",
                     writable: Bool = true) throws -> (XfsVolume, FileDriver, XfsItem) {
    let driver = FileDriver()
    driver.files[filePath] = Array(contents.utf8)
    let access = writable
        ? try XfsMountPolicy.readWrite.authorize(deviceIsWritable: true, mountedDriver: .success(true))
        : .readOnly
    let volume = XfsVolume(volumeID: FSVolume.Identifier(), volumeName: FSFileName(string: "w"),
                           driver: driver, contextPtr: nil, bsdName: "write-test",
                           stats: IOStatsCollector(label: "write-test", emit: { _ in }),
                           mountAccess: access)
    let item = volume.item(forInode: 128, path: filePath, parentInode: 64)
    return (volume, driver, item)
}

private func readBack(_ volume: XfsVolume, _ item: XfsItem) throws -> String {
    var buffer = [UInt8](repeating: 0, count: 64)
    let n = try buffer.withUnsafeMutableBytes {
        try volume.readBytes(from: item, at: 0, into: $0)
    }
    return String(decoding: buffer.prefix(n), as: UTF8.self)
}

@Suite("XFS FSKit writes and truncate")
struct XfsWriteTests {

    @Test func writeAtZeroAnswersTheCountAndTheBytesReadBack() async throws {
        let (volume, driver, item) = try fixture()
        let n = try await volume.write(contents: Data("HELLO".utf8), to: item, at: 0)
        #expect(n == 5)
        #expect(try readBack(volume, item) == "HELLO world")
        #expect(driver.writes.count == 1)
        #expect(driver.writes.first?.0 == filePath)
        #expect(driver.writes.first?.1 == 0)
    }

    @Test func overwriteAtAnOffsetLandsAtThatOffset() async throws {
        let (volume, _, item) = try fixture()
        let n = try await volume.write(contents: Data("WORLD".utf8), to: item, at: 6)
        #expect(n == 5)
        #expect(try readBack(volume, item) == "hello WORLD")
    }

    /// The published driver cannot allocate. Its refusal reaches FSKit as
    /// itself, never as a zero-byte success that a copy would treat as done.
    @Test func extendingWriteAnswersTheDriversENOTSUP() async throws {
        let (volume, _, item) = try fixture()
        await #expect(throws: POSIXError(.ENOTSUP)) {
            try await volume.write(contents: Data("!!".utf8), to: item, at: 10)
        }
        #expect(try readBack(volume, item) == "hello world")
    }

    @Test func emptyWriteAnswersZeroWithoutCallingTheDriver() async throws {
        let (volume, driver, item) = try fixture()
        let n = try await volume.write(contents: Data(), to: item, at: 3)
        #expect(n == 0)
        #expect(driver.writes.isEmpty)
    }

    @Test func negativeOffsetIsEINVAL() async throws {
        let (volume, driver, item) = try fixture()
        await #expect(throws: POSIXError(.EINVAL)) {
            try await volume.write(contents: Data("x".utf8), to: item, at: -1)
        }
        #expect(driver.writes.isEmpty)
    }

    @Test func readOnlyMountRefusesWritesBeforeTheDriver() async throws {
        let (volume, driver, item) = try fixture(writable: false)
        await #expect(throws: POSIXError(.EROFS)) {
            try await volume.write(contents: Data("x".utf8), to: item, at: 0)
        }
        let request = FSItem.SetAttributesRequest()
        request.size = 1
        await #expect(throws: POSIXError(.EROFS)) {
            try await volume.setAttributes(request, on: item)
        }
        #expect(driver.writes.isEmpty)
        #expect(driver.truncates.isEmpty)
    }

    @Test func truncateShortensConsumesSizeAndAnswersTheNewSize() async throws {
        let (volume, driver, item) = try fixture()
        let request = FSItem.SetAttributesRequest()
        request.size = 5
        let attributes = try await volume.setAttributes(request, on: item)
        #expect(attributes.size == 5)
        #expect(request.wasAttributeConsumed(.size))
        #expect(try readBack(volume, item) == "hello")
        // A size change moves mtime; none was given, so the volume stamps one.
        #expect(driver.truncates.count == 1)
        #expect(driver.truncates.first?.2 != nil)
    }

    @Test func truncateCarriesARequestedModifyTime() async throws {
        let (volume, driver, item) = try fixture()
        let request = FSItem.SetAttributesRequest()
        request.size = 0
        request.modifyTime = timespec(tv_sec: -86400, tv_nsec: 7)
        _ = try await volume.setAttributes(request, on: item)
        #expect(request.wasAttributeConsumed(.size))
        #expect(request.wasAttributeConsumed(.modifyTime))
        #expect(driver.truncates.first?.2?.tv_sec == -86400)
        #expect(driver.truncates.first?.2?.tv_nsec == 7)
    }

    @Test func growingTruncateAnswersTheDriversENOTSUP() async throws {
        let (volume, _, item) = try fixture()
        let request = FSItem.SetAttributesRequest()
        request.size = 4096
        await #expect(throws: POSIXError(.ENOTSUP)) {
            try await volume.setAttributes(request, on: item)
        }
        #expect(!request.wasAttributeConsumed(.size))
        #expect(try readBack(volume, item) == "hello world")
    }

    /// Mode, ownership and access times belong to #323. A request that
    /// carries one is refused whole, before the size is touched, so no
    /// half-applied request is reported as a failure.
    @Test(arguments: [FSItem.Attribute.mode, .uid, .gid, .accessTime])
    func unmappedAttributeRefusesTheWholeRequest(_ attribute: FSItem.Attribute) async throws {
        let (volume, driver, item) = try fixture()
        let request = FSItem.SetAttributesRequest()
        request.size = 1
        switch attribute {
        case .mode: request.mode = 0o600
        case .uid: request.uid = 501
        case .gid: request.gid = 20
        default: request.accessTime = timespec(tv_sec: 1, tv_nsec: 0)
        }
        await #expect(throws: POSIXError(.ENOTSUP)) {
            try await volume.setAttributes(request, on: item)
        }
        #expect(driver.truncates.isEmpty)
        #expect(try readBack(volume, item) == "hello world")
    }

    @Test func modifyTimeAloneIsNotYetMapped() async throws {
        let (volume, driver, item) = try fixture()
        let request = FSItem.SetAttributesRequest()
        request.modifyTime = timespec(tv_sec: 1, tv_nsec: 0)
        await #expect(throws: POSIXError(.ENOTSUP)) {
            try await volume.setAttributes(request, on: item)
        }
        #expect(driver.truncates.isEmpty)
    }
}
