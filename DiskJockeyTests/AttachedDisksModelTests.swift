//
//  AttachedDisksModelTests.swift — covers parseMountLine() so we don't
//  need to spawn /sbin/mount in tests. The parser produces the
//  isWritable flag the sidebar / detail UI render.
//

import Testing
@testable import DiskJockey

struct AttachedDisksModelTests {
    private static let interesting: Set<String> = ["ext4", "ntfs", "fsntfs"]

    @Test func testParseRO() throws {
        let line = "/dev/disk5s2 on /Volumes/rootfs (ext4, local, read-only, fskit)"
        let disk = try #require(
            AttachedDisksModel.parseMountLine(line, fsTypesOfInterest: Self.interesting)
        )
        #expect(disk.isWritable == false)
        #expect(disk.fsType == "ext4")
        #expect(disk.mountPath == "/Volumes/rootfs")
        #expect(disk.devicePath == "/dev/disk5s2")
    }

    @Test func testParseRW() throws {
        let line = "/dev/disk5s2 on /Volumes/rootfs (ext4, local, fskit)"
        let disk = try #require(
            AttachedDisksModel.parseMountLine(line, fsTypesOfInterest: Self.interesting)
        )
        #expect(disk.isWritable == true)
        #expect(disk.fsType == "ext4")
    }

    @Test func testParseLegacyROToken() throws {
        let line = "/dev/disk5s2 on /Volumes/rootfs (ext4, ro, fskit)"
        let disk = try #require(
            AttachedDisksModel.parseMountLine(line, fsTypesOfInterest: Self.interesting)
        )
        #expect(disk.isWritable == false)
    }
}
