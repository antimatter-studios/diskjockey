//
// MountTableParserTests.swift — coverage for the static parsing layer
// extracted from `AttachedDisksModel`. These tests don't spawn a real
// `/sbin/mount` — `parseMountLine` is the unit, the orchestration in
// `enumerate` is exercised by the running app.
//

import Testing
@testable import DiskJockey

struct MountTableParserTests {
    private static let interesting: Set<String> = ["ext4", "ntfs", "fsntfs"]

    // MARK: - parseMountLine

    @Test func testParseRW() throws {
        let line = "/dev/disk5s2 on /Volumes/rootfs (ext4, local, fskit)"
        let disk = try #require(
            MountTableParser.parseMountLine(line, fsTypesOfInterest: Self.interesting)
        )
        #expect(disk.isWritable == true)
        #expect(disk.fsType == "ext4")
        #expect(disk.mountPath == "/Volumes/rootfs")
        #expect(disk.devicePath == "/dev/disk5s2")
        #expect(disk.bsd == "disk5s2")
        #expect(disk.name == "rootfs")
    }

    @Test func testParseRO() throws {
        let line = "/dev/disk5s2 on /Volumes/rootfs (ext4, local, read-only, fskit)"
        let disk = try #require(
            MountTableParser.parseMountLine(line, fsTypesOfInterest: Self.interesting)
        )
        #expect(disk.isWritable == false)
    }

    @Test func testParseLegacyROToken() throws {
        let line = "/dev/disk5s2 on /Volumes/rootfs (ext4, ro, fskit)"
        let disk = try #require(
            MountTableParser.parseMountLine(line, fsTypesOfInterest: Self.interesting)
        )
        #expect(disk.isWritable == false)
    }

    @Test func testFstypeOutsideInterestReturnsNil() {
        let line = "/dev/disk5s2 on /Volumes/rootfs (apfs, local)"
        let disk = MountTableParser.parseMountLine(line, fsTypesOfInterest: Self.interesting)
        #expect(disk == nil)
    }

    @Test func testMalformedLineReturnsNil() {
        #expect(MountTableParser.parseMountLine("",
                                                fsTypesOfInterest: Self.interesting) == nil)
        #expect(MountTableParser.parseMountLine("not a mount line",
                                                fsTypesOfInterest: Self.interesting) == nil)
        #expect(MountTableParser.parseMountLine("/dev/disk5s2 on /Volumes/rootfs ext4",
                                                fsTypesOfInterest: Self.interesting) == nil)
    }

    @Test func testNtfsParse() throws {
        let line = "/dev/disk6s1 on /Volumes/WinData (ntfs, local, nodev, nosuid, read-only)"
        let disk = try #require(
            MountTableParser.parseMountLine(line, fsTypesOfInterest: Self.interesting)
        )
        #expect(disk.fsType == "ntfs")
        #expect(disk.isWritable == false)
        #expect(disk.bsd == "disk6s1")
    }

    // MARK: - bsdName

    @Test func testBsdNameStripsDevPrefix() {
        #expect(MountTableParser.bsdName(from: "/dev/disk5s1") == "disk5s1")
        #expect(MountTableParser.bsdName(from: "/dev/disk0") == "disk0")
    }

    @Test func testBsdNameLeavesNonDevUnchanged() {
        #expect(MountTableParser.bsdName(from: "disk5s1") == "disk5s1")
        #expect(MountTableParser.bsdName(from: "") == "")
    }

    // MARK: - isWholeDiskBSD

    @Test func testIsWholeDiskBSDAcceptsBareDisks() {
        #expect(MountTableParser.isWholeDiskBSD("disk0") == true)
        #expect(MountTableParser.isWholeDiskBSD("disk4") == true)
        #expect(MountTableParser.isWholeDiskBSD("disk42") == true)
    }

    @Test func testIsWholeDiskBSDRejectsSlices() {
        #expect(MountTableParser.isWholeDiskBSD("disk4s1") == false)
        #expect(MountTableParser.isWholeDiskBSD("disk4s1s2") == false)
    }

    @Test func testIsWholeDiskBSDRejectsMalformed() {
        // Must have at least one digit after "disk"; bare "disk" doesn't
        // match the anchored `^disk\d+$` regex the model relies on.
        #expect(MountTableParser.isWholeDiskBSD("disk") == false)
        #expect(MountTableParser.isWholeDiskBSD("") == false)
        #expect(MountTableParser.isWholeDiskBSD("foo") == false)
        #expect(MountTableParser.isWholeDiskBSD("rdisk4") == false)
    }
}
