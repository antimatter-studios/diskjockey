//
// DiskEventHandlerTests.swift — coverage for the static event-to-state
// transforms extracted from `AttachedDisksModel`. The model layer
// still owns `disks` mutation; these tests exercise the pure
// functions that decode an event and mutate an `inout AttachedDisk`.
//

import Testing
import Foundation
@testable import DiskJockey

struct DiskEventHandlerTests {

    private func freshDisk(bsd: String = "disk5s1",
                           fsType: String = "",
                           name: String = "disk5s1") -> AttachedDisk {
        AttachedDisk(
            bsd: bsd,
            mountPath: "",
            devicePath: "/dev/\(bsd)",
            fsType: fsType,
            name: name,
            isWritable: true,
            status: .mounting
        )
    }

    // MARK: - fsTypeFromEventKind

    @Test func testFsTypeFromKnownPrefixes() {
        #expect(DiskEventHandler.fsTypeFromEventKind("ext4.probe") == "ext4")
        #expect(DiskEventHandler.fsTypeFromEventKind("ext4.load") == "ext4")
        #expect(DiskEventHandler.fsTypeFromEventKind("ntfs.probe") == "ntfs")
    }

    @Test func testFsTypeForUnrelatedKindsIsNil() {
        #expect(DiskEventHandler.fsTypeFromEventKind("fsck.progress") == nil)
        #expect(DiskEventHandler.fsTypeFromEventKind("io.stats") == nil)
        #expect(DiskEventHandler.fsTypeFromEventKind("volume.info") == nil)
        #expect(DiskEventHandler.fsTypeFromEventKind("") == nil)
    }

    // MARK: - fsckStatus dispatch

    @Test func testFsckStatusVolumeCleanDirty() {
        var disk = freshDisk()
        #expect(DiskEventHandler.fsckStatus(kind: "volume.clean",
                                            fields: [:], disk: &disk) == .clean)
        #expect(DiskEventHandler.fsckStatus(kind: "volume.dirty",
                                            fields: [:], disk: &disk) == .dirty)
    }

    @Test func testFsckStatusStart() {
        var disk = freshDisk()
        let status = DiskEventHandler.fsckStatus(
            kind: "fsck.start", fields: [:], disk: &disk
        )
        #expect(status == .running(phase: "starting", done: 0, total: 0))
    }

    @Test func testFsckStatusProgressDecodesFields() {
        var disk = freshDisk()
        let status = DiskEventHandler.fsckStatus(
            kind: "fsck.progress",
            fields: ["phase": "inodes", "done": "42", "total": "100"],
            disk: &disk
        )
        #expect(status == .running(phase: "inodes", done: 42, total: 100))
    }

    @Test func testFsckStatusDoneSetsLastRepairAndAnomalies() {
        var disk = freshDisk()
        let status = DiskEventHandler.fsckStatus(
            kind: "fsck.done",
            fields: [
                "dirty_cleared": "true",
                "logfile_bytes": "4096",
                "repaired_count": "7",
                "anomalies": "3",
            ],
            disk: &disk
        )
        #expect(status == .completed(dirtyCleared: true, logfileBytes: 4096))
        #expect(disk.lastRepairedCount == 7)
        #expect(disk.lastAnomaliesFound == 3)
    }

    @Test func testFsckStatusFailedCarriesErrorMessage() {
        var disk = freshDisk()
        let status = DiskEventHandler.fsckStatus(
            kind: "fsck.failed",
            fields: ["error": "checksum mismatch"],
            disk: &disk
        )
        #expect(status == .failed("checksum mismatch"))
    }

    @Test func testFsckStatusUnknownKindReturnsNil() {
        var disk = freshDisk()
        #expect(DiskEventHandler.fsckStatus(kind: "io.stats", fields: [:],
                                            disk: &disk) == nil)
    }

    // MARK: - applyVolumeInfo

    @Test func testApplyVolumeInfoSetsFsTypeAndAdoptsVolumeName() {
        var disk = freshDisk(fsType: "", name: "disk5s1")
        // disk.name == disk.bsd → the row is still showing the BSD as a
        // placeholder, so volume_name must be adopted.
        DiskEventHandler.applyVolumeInfo(
            fields: ["fs": "ext4", "volume_name": "rootfs"],
            to: &disk
        )
        #expect(disk.fsType == "ext4")
        #expect(disk.name == "rootfs")
    }

    @Test func testApplyVolumeInfoDoesNotClobberMountVolumeName() {
        // Once mount(8) has assigned a real /Volumes path, that's
        // the user-visible name — adopting volume_name would clobber it.
        var disk = freshDisk(fsType: "ext4", name: "rootfs-from-mount")
        DiskEventHandler.applyVolumeInfo(
            fields: ["fs": "ext4", "volume_name": "on-disk-label"],
            to: &disk
        )
        #expect(disk.name == "rootfs-from-mount")
    }

    @Test func testApplyVolumeInfoMaterializesExt4TotalSize() {
        var disk = freshDisk(fsType: "ext4")
        DiskEventHandler.applyVolumeInfo(
            fields: [
                "fs": "ext4",
                "total_blocks": "1000",
                "block_size": "4096",
            ],
            to: &disk
        )
        // 1000 * 4096 = 4_096_000
        #expect(disk.info["total_size"] == "4096000")
    }

    @Test func testApplyVolumeInfoAssignsStableIdentityFromUUID() {
        var disk = freshDisk()
        DiskEventHandler.applyVolumeInfo(
            fields: ["fs": "ext4", "volume_uuid": "abcd-1234"],
            to: &disk
        )
        #expect(disk.stableIdentity == "ext4-uuid:abcd-1234")
    }

    @Test func testApplyVolumeInfoAssignsStableIdentityFromNtfsSerial() {
        var disk = freshDisk()
        DiskEventHandler.applyVolumeInfo(
            fields: ["fs": "ntfs", "serial_number": "ABCD1234"],
            to: &disk
        )
        #expect(disk.stableIdentity == "ntfs-serial:ABCD1234")
    }

    // MARK: - materializeTotalSize

    @Test func testMaterializeTotalSizeExt4() {
        #expect(DiskEventHandler.materializeTotalSize(
            from: ["fs": "ext4", "total_blocks": "100", "block_size": "4096"]
        ) == 409_600)
    }

    @Test func testMaterializeTotalSizeNtfs() {
        #expect(DiskEventHandler.materializeTotalSize(
            from: ["fs": "ntfs", "total_size": "12345"]
        ) == 12_345)
    }

    @Test func testMaterializeTotalSizeUnknownFsReturnsNil() {
        #expect(DiskEventHandler.materializeTotalSize(
            from: ["fs": "apfs", "size": "999"]
        ) == nil)
        #expect(DiskEventHandler.materializeTotalSize(from: [:]) == nil)
    }

    @Test func testMaterializeTotalSizeExt4OverflowReturnsNil() {
        // UInt64.max * 2 overflows; helper must return nil rather than
        // wrap. Use realistic-looking fields that just happen to overflow.
        #expect(DiskEventHandler.materializeTotalSize(
            from: [
                "fs": "ext4",
                "total_blocks": String(UInt64.max),
                "block_size": "2",
            ]
        ) == nil)
    }

    // MARK: - applyEventInPlace dispatch

    @Test func testApplyEventInPlaceVolumeInfoRoutesToVolumeInfoHandler() {
        var disk = freshDisk(name: "disk5s1")
        DiskEventHandler.applyEventInPlace(
            kind: "volume.info",
            fields: ["fs": "ext4", "volume_name": "rootfs"],
            to: &disk
        )
        #expect(disk.fsType == "ext4")
        #expect(disk.name == "rootfs")
    }

    @Test func testApplyEventInPlaceFsckProgressSetsFsckStatus() {
        var disk = freshDisk()
        DiskEventHandler.applyEventInPlace(
            kind: "fsck.progress",
            fields: ["phase": "blocks", "done": "5", "total": "10"],
            to: &disk
        )
        #expect(disk.fsckStatus == .running(phase: "blocks", done: 5, total: 10))
    }

    @Test func testApplyEventInPlaceUnknownKindIsNoOp() {
        var disk = freshDisk()
        let originalFsck = disk.fsckStatus
        DiskEventHandler.applyEventInPlace(
            kind: "unknown.kind", fields: [:], to: &disk
        )
        #expect(disk.fsckStatus == originalFsck)
    }
}
