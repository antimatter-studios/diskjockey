//
//  ReadOnlyVolumeSupportTests.swift — the first tests in this project
//  that exercise read-only volume logic rather than a mirror of it.
//
//  Every existing volume test builds a mock that imitates the volume's
//  wiring, because the volume classes live in extension targets a test
//  bundle cannot see. A mirror asserts only what the mirror was written
//  to say, which is why the XFS volume could ship claiming it had no
//  journal and no test noticed.
//
//  These run against the real code the volumes will call.
//

import Testing
import FSKit
@testable import DiskJockeyLibrary

// MARK: - Capacity, where the filesystems genuinely disagree

@Suite("statfs")
struct ReadOnlyStatFSTests {

    /// The block-counting filesystems pass their figures through.
    @Test func blockCapacityIsReportedAsGiven() {
        let info = ReadOnlyVolumeInfo(
            capacity: .blocks(blockSize: 4096, total: 1000, free: 250),
            ioSize: 4096,
            totalInodes: 64,
            freeInodes: 60)
        let r = ReadOnlyVolumeSupport.statFS(info, fileSystemTypeName: "xfs")

        #expect(r.blockSize == 4096)
        #expect(r.totalBlocks == 1000)
        #expect(r.freeBlocks == 250)
        #expect(r.availableBlocks == 0,
                "read-only: free describes the image, available describes this mount")
        #expect(r.totalFiles == 64)
        #expect(r.freeFiles == 60)
    }

    /// Btrfs reports bytes, and the division has to happen somewhere.
    ///
    /// 8 GiB total, 2 GiB used, 4 KiB sectors — so 2,097,152 sectors of
    /// which 524,288 are used, leaving 1,572,864 free.
    @Test func byteCapacityIsDividedIntoSectors() {
        let info = ReadOnlyVolumeInfo(
            capacity: .bytes(sectorSize: 4096,
                             total: 8 * 1024 * 1024 * 1024,
                             used: 2 * 1024 * 1024 * 1024),
            ioSize: 16384)
        let r = ReadOnlyVolumeSupport.statFS(info, fileSystemTypeName: "btrfs")

        #expect(r.blockSize == 4096)
        #expect(r.totalBlocks == 2_097_152)
        #expect(r.freeBlocks == 1_572_864)
        #expect(r.availableBlocks == 0)
    }

    /// Btrfs advertises its node size for I/O, which is not its sector
    /// size. Reporting the block size for both would understate the
    /// useful read unit fourfold.
    @Test func ioSizeIsIndependentOfBlockSize() {
        let info = ReadOnlyVolumeInfo(
            capacity: .bytes(sectorSize: 4096, total: 4096 * 10, used: 0),
            ioSize: 16384)
        let r = ReadOnlyVolumeSupport.statFS(info, fileSystemTypeName: "btrfs")

        #expect(r.blockSize == 4096)
        #expect(r.ioSize == 16384)
    }

    /// A driver that has not finished mounting reports a zero sector
    /// size. Dividing by it would trap.
    @Test func aZeroSectorSizeDoesNotDivide() {
        let info = ReadOnlyVolumeInfo(
            capacity: .bytes(sectorSize: 0, total: 999, used: 1),
            ioSize: 0)
        let r = ReadOnlyVolumeSupport.statFS(info, fileSystemTypeName: "btrfs")

        #expect(r.totalBlocks == 0)
        #expect(r.freeBlocks == 0)
        #expect(r.availableBlocks == 0)
    }

    /// More used than total is a corrupt image. The subtraction must
    /// saturate: an unsigned wrap would report roughly sixteen exabytes
    /// free on a full disk, which is worse than reporting none.
    @Test func moreUsedThanTotalReportsNoFreeSpaceRatherThanWrapping() {
        let info = ReadOnlyVolumeInfo(
            capacity: .bytes(sectorSize: 4096, total: 4096, used: 8192),
            ioSize: 4096)
        let r = ReadOnlyVolumeSupport.statFS(info, fileSystemTypeName: "btrfs")

        #expect(r.totalBlocks == 1)
        #expect(r.freeBlocks == 0)
        #expect(r.availableBlocks == 0)
    }

    /// A compressed image is exactly as large as its contents, so used
    /// is total and nothing is free. 40 KiB used with 4 KiB blocks is
    /// ten blocks, all of them occupied.
    @Test func aCompressedImageReportsUsedAsTotalAndNothingFree() {
        let info = ReadOnlyVolumeInfo(
            capacity: .compressedImage(blockSize: 4096, usedBytes: 40960),
            ioSize: 4096,
            totalInodes: 12)
        let r = ReadOnlyVolumeSupport.statFS(info, fileSystemTypeName: "squashfs")

        #expect(r.blockSize == 4096)
        #expect(r.totalBlocks == 10)
        #expect(r.freeBlocks == 0)
        #expect(r.availableBlocks == 0)
        #expect(r.totalFiles == 12)
    }

    @Test func aCompressedImageWithNoBlockSizeDoesNotDivide() {
        let info = ReadOnlyVolumeInfo(
            capacity: .compressedImage(blockSize: 0, usedBytes: 999),
            ioSize: 0)
        let r = ReadOnlyVolumeSupport.statFS(info, fileSystemTypeName: "squashfs")
        #expect(r.totalBlocks == 0)
        #expect(r.freeBlocks == 0)
    }

    /// A filesystem with no fixed inode table has no count to give.
    /// Zero is the honest answer; a figure derived from the byte
    /// totals would be one a user could act on wrongly.
    @Test func absentInodeCountsBecomeZero() {
        let info = ReadOnlyVolumeInfo(
            capacity: .bytes(sectorSize: 4096, total: 4096, used: 0),
            ioSize: 4096,
            totalInodes: nil,
            freeInodes: nil)
        let r = ReadOnlyVolumeSupport.statFS(info, fileSystemTypeName: "btrfs")

        #expect(r.totalFiles == 0)
        #expect(r.freeFiles == 0)
    }
}

// MARK: - Capabilities, the flag that was actually wrong in production

@Suite("capabilities")
struct ReadOnlyCapabilityTests {

    /// The regression this whole module exists for. The XFS volume
    /// shipped with `supportsJournal = false`, inherited from the EROFS
    /// volume it was copied from. Journalling is now a parameter, so
    /// the answer cannot be inherited by accident.
    @Test func journallingIsCarriedThroughInBothDirections() {
        let journalled = ReadOnlyVolumeCapabilities(hasJournal: true)
        #expect(journalled.fsCapabilities.supportsJournal == true)

        let notJournalled = ReadOnlyVolumeCapabilities(hasJournal: false)
        #expect(notJournalled.fsCapabilities.supportsJournal == false)
    }

    /// A journal these drivers never replay is never active. This holds
    /// even for the journalled filesystems, so it is not a parameter.
    @Test func theJournalIsNeverActive() {
        for hasJournal in [true, false] {
            let caps = ReadOnlyVolumeCapabilities(hasJournal: hasJournal)
            #expect(caps.fsCapabilities.supportsActiveJournal == false,
                    "a driver that refuses a dirty log never has an active journal")
        }
    }

    /// The invariants, asserted so that a future edit to the shared
    /// block has to be deliberate rather than silent.
    @Test func theFixedCapabilitiesAreFixed() {
        let caps = ReadOnlyVolumeCapabilities(hasJournal: true).fsCapabilities
        #expect(caps.supportsPersistentObjectIDs == true)
        #expect(caps.supportsHardLinks == false)
        #expect(caps.supports64BitObjectIDs == true)
    }

    /// SquashFS advertises 32-bit identifiers where the others
    /// advertise 64-bit. It is a statement about the format, so it is a
    /// parameter rather than a value normalised to the majority.
    @Test func objectIDWidthIsAParameter() {
        #expect(ReadOnlyVolumeCapabilities(hasJournal: false)
            .fsCapabilities.supports64BitObjectIDs == true)
        #expect(ReadOnlyVolumeCapabilities(hasJournal: false, supports64BitObjectIDs: false)
            .fsCapabilities.supports64BitObjectIDs == false)
    }

    @Test func caseSensitivityAndSymlinksAreParameters() {
        let sensitive = ReadOnlyVolumeCapabilities(
            hasJournal: false, supportsSymbolicLinks: false, isCaseSensitive: true)
        #expect(sensitive.fsCapabilities.caseFormat == .sensitive)
        #expect(sensitive.fsCapabilities.supportsSymbolicLinks == false)

        let insensitive = ReadOnlyVolumeCapabilities(
            hasJournal: false, supportsSymbolicLinks: true, isCaseSensitive: false)
        #expect(insensitive.fsCapabilities.caseFormat == .insensitive)
        #expect(insensitive.fsCapabilities.supportsSymbolicLinks == true)
    }
}

// MARK: - Paths and attributes

@Suite("paths and attributes")
struct ReadOnlyAttributeTests {

    /// Joining onto root must not double the separator. `//name` names
    /// the same file but is a different cache key.
    @Test func joiningOntoRootDoesNotDoubleTheSeparator() {
        #expect(ReadOnlyVolumeSupport.joinPath("/", "etc") == "/etc")
        #expect(ReadOnlyVolumeSupport.joinPath("/etc", "hosts") == "/etc/hosts")
        #expect(ReadOnlyVolumeSupport.joinPath("/a/b", "c") == "/a/b/c")
    }

    private func sample(_ type: ReadOnlyFileType = .file,
                        inode: UInt64 = 42,
                        size: UInt64 = 1234) -> ReadOnlyFileAttributes {
        ReadOnlyFileAttributes(inode: inode, mode: 0o644, uid: 501, gid: 20,
                               size: size, linkCount: 1, mtime: 1_700_000_000,
                               fileType: type)
    }

    @Test func attributesCarryThrough() {
        let a = ReadOnlyVolumeSupport.fsAttributes(from: sample(), parentInode: 7)
        #expect(a.mode == 0o644)
        #expect(a.uid == 501)
        #expect(a.gid == 20)
        #expect(a.size == 1234)
        #expect(a.linkCount == 1)
        #expect(a.fileID.rawValue == 42)
        #expect(a.parentID.rawValue == 7)
    }

    /// Read-only and not sparse-aware, so allocated size is the size.
    /// Reporting zero here makes `du` disagree with `ls` on every file.
    @Test func allocatedSizeMatchesSize() {
        let a = ReadOnlyVolumeSupport.fsAttributes(from: sample(size: 9999),
                                                   parentInode: nil)
        #expect(a.allocSize == 9999)
    }

    /// The drivers report one timestamp. All four are set from it
    /// deliberately — leaving the others unset shows the epoch in
    /// Finder, and one honest value repeated beats three wrong ones.
    @Test func allFourTimestampsComeFromTheOneTheDriverGives() {
        let a = ReadOnlyVolumeSupport.fsAttributes(from: sample(), parentInode: nil)
        #expect(a.accessTime.tv_sec == 1_700_000_000)
        #expect(a.modifyTime.tv_sec == 1_700_000_000)
        #expect(a.changeTime.tv_sec == 1_700_000_000)
        #expect(a.birthTime.tv_sec == 1_700_000_000)
    }

    /// A driver that reports all four times has each one shown as itself:
    /// on a writable volume, a time that was set must read back unchanged.
    @Test func reportedTimesAreShownAsThemselves() {
        var attr = sample()
        attr.atime = -1
        attr.ctime = 1_750_000_000
        attr.birthtime = 1_600_000_000
        let a = ReadOnlyVolumeSupport.fsAttributes(from: attr, parentInode: nil)
        #expect(a.accessTime.tv_sec == -1)
        #expect(a.modifyTime.tv_sec == 1_700_000_000)
        #expect(a.changeTime.tv_sec == 1_750_000_000)
        #expect(a.birthTime.tv_sec == 1_600_000_000)
    }

    /// Root has no parent, and reports itself.
    @Test func anAbsentParentBecomesRoot() {
        let a = ReadOnlyVolumeSupport.fsAttributes(from: sample(), parentInode: nil)
        #expect(a.parentID.rawValue == 1)
    }

    @Test func fileTypesMapToFSKit() {
        #expect(ReadOnlyFileType.file.fsItemType == .file)
        #expect(ReadOnlyFileType.directory.fsItemType == .directory)
        #expect(ReadOnlyFileType.symlink.fsItemType == .symlink)
        // Sockets, fifos and devices cannot appear in an image these
        // drivers mount read-only, and FSKit has no case for them.
        #expect(ReadOnlyFileType.other.fsItemType == .file)
    }
}
