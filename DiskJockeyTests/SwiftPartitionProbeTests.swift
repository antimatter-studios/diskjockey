//
//  SwiftPartitionProbeTests.swift — unit tests for the pure filesystem
//  signature detection functions in SwiftPartitionProbe.
//
//  classify() and classifyExt() take only a [UInt8] / Data value with no
//  I/O, so they can be fully exercised here without a real disk image.
//

import Foundation
import Testing
@testable import DiskJockey

// MARK: - classify() tests

struct ClassifyTests {

    // Helpers to build minimal sector/superblock buffers.

    private func buffer(size: Int = 4096, fill: UInt8 = 0) -> [UInt8] {
        [UInt8](repeating: fill, count: size)
    }

    private func data(size: Int = 4096) -> Data {
        Data(count: size)
    }

    // Place bytes starting at `offset` into a mutable buffer.
    private func buf(size: Int = 4096, bytes: [UInt8], at offset: Int) -> Data {
        var d = Data(count: size)
        d.replaceSubrange(offset..<offset + bytes.count, with: bytes)
        return d
    }

    // MARK: Unknown / empty

    @Test func emptyBufferIsUnknown() {
        #expect(SwiftPartitionProbe.classify(Data()) == "unknown")
    }

    @Test func allZeroesIsUnknown() {
        #expect(SwiftPartitionProbe.classify(data()) == "unknown")
    }

    // MARK: SquashFS

    @Test func squashfsMagicAtOffset0() {
        let d = buf(bytes: [0x68, 0x73, 0x71, 0x73], at: 0)
        #expect(SwiftPartitionProbe.classify(d) == "squashfs")
    }

    // MARK: NTFS / FAT / exFAT (boot sector family)

    private func bootSector(oem: String) -> Data {
        var d = Data(count: 512)
        // Boot sector signature at 510-511.
        d[510] = 0x55; d[511] = 0xAA
        // OEM string at bytes 3-10.
        let oemBytes = Array(oem.utf8)
        d.replaceSubrange(3..<3+oemBytes.count, with: oemBytes)
        return d
    }

    @Test func ntfsOEMStringDetected() {
        #expect(SwiftPartitionProbe.classify(bootSector(oem: "NTFS    ")) == "ntfs")
    }

    @Test func exfatOEMStringDetected() {
        #expect(SwiftPartitionProbe.classify(bootSector(oem: "EXFAT   ")) == "exfat")
    }

    @Test func fat32FileSystemTypeDetected() {
        var d = Data(count: 512)
        d[510] = 0x55; d[511] = 0xAA
        let fat32 = Array("FAT32   ".utf8)
        d.replaceSubrange(0x52..<0x52+fat32.count, with: fat32)
        #expect(SwiftPartitionProbe.classify(d) == "fat32")
    }

    @Test func fat16FileSystemTypeDetected() {
        var d = Data(count: 512)
        d[510] = 0x55; d[511] = 0xAA
        let fat16 = Array("FAT16   ".utf8)
        d.replaceSubrange(0x36..<0x36+fat16.count, with: fat16)
        #expect(SwiftPartitionProbe.classify(d) == "fat16")
    }

    @Test func bootSectorWithoutOEMIsNotNtfs() {
        // Valid 0x55AA signature but no OEM string → not NTFS/FAT.
        var d = Data(count: 512)
        d[510] = 0x55; d[511] = 0xAA
        // Result falls through to "unknown" (no other magic matches).
        #expect(SwiftPartitionProbe.classify(d) == "unknown")
    }

    // MARK: ext2/3/4

    private func extBuffer(incompat: UInt32 = 0, compat: UInt32 = 0) -> Data {
        var d = Data(count: 0x9000)
        // ext magic at byte 1080 (superblock offset 56).
        d[1080] = 0x53; d[1081] = 0xEF
        // Superblock base = 1024.
        let sb = 1024
        // s_feature_incompat at sb+0x60
        d[sb+0x60] = UInt8(incompat & 0xFF)
        d[sb+0x61] = UInt8((incompat >> 8) & 0xFF)
        d[sb+0x62] = UInt8((incompat >> 16) & 0xFF)
        d[sb+0x63] = UInt8((incompat >> 24) & 0xFF)
        // s_feature_compat at sb+0x5C
        d[sb+0x5C] = UInt8(compat & 0xFF)
        d[sb+0x5D] = UInt8((compat >> 8) & 0xFF)
        d[sb+0x5E] = UInt8((compat >> 16) & 0xFF)
        d[sb+0x5F] = UInt8((compat >> 24) & 0xFF)
        return d
    }

    @Test func ext2DetectedWhenNoFeatureFlags() {
        #expect(SwiftPartitionProbe.classify(extBuffer()) == "ext2")
    }

    @Test func ext3DetectedByJournalCompatFlag() {
        // COMPAT_HAS_JOURNAL = 0x0004
        #expect(SwiftPartitionProbe.classify(extBuffer(compat: 0x0004)) == "ext3")
    }

    @Test func ext4DetectedByExtentsIncompatFlag() {
        // INCOMPAT_EXTENTS = 0x1000
        #expect(SwiftPartitionProbe.classify(extBuffer(incompat: 0x1000)) == "ext4")
    }

    @Test func ext4IncompatTakesPriorityOverExt3Compat() {
        #expect(SwiftPartitionProbe.classify(extBuffer(incompat: 0x1000, compat: 0x0004)) == "ext4")
    }

    // MARK: HFS+

    @Test func hfsPlusMagicDetected() {
        var d = Data(count: 1200)
        d[1024] = 0x48; d[1025] = 0x2B  // 'H+'
        #expect(SwiftPartitionProbe.classify(d) == "hfs_plus")
    }

    @Test func hfsPlusWrappedHFSMagicDetected() {
        var d = Data(count: 1200)
        d[1024] = 0x48; d[1025] = 0x58  // 'HX'
        #expect(SwiftPartitionProbe.classify(d) == "hfs_plus")
    }

    // MARK: APFS

    @Test func apfsMagicDetected() {
        var d = Data(count: 100)
        let nxsb = Array("NXSB".utf8)
        d.replaceSubrange(32..<36, with: nxsb)
        #expect(SwiftPartitionProbe.classify(d) == "apfs")
    }

    // MARK: Linux swap

    @Test func linuxSwapDetectedAtDefaultPageSize() {
        var d = Data(count: 4096)
        let sig = Array("SWAPSPACE2".utf8)
        d.replaceSubrange((4096-10)..<4096, with: sig)
        #expect(SwiftPartitionProbe.classify(d) == "linux_swap")
    }

    @Test func linuxSwapDetectedAt8KPageSize() {
        var d = Data(count: 8192)
        let sig = Array("SWAPSPACE2".utf8)
        d.replaceSubrange((8192-10)..<8192, with: sig)
        #expect(SwiftPartitionProbe.classify(d) == "linux_swap")
    }

    // MARK: ISO 9660

    @Test func iso9660MagicDetected() {
        var d = Data(count: 0x9000)
        let cd001 = Array("CD001".utf8)
        d.replaceSubrange(0x8001..<0x8006, with: cd001)
        #expect(SwiftPartitionProbe.classify(d) == "iso9660")
    }
}

// MARK: - classifyExt() tests

struct ClassifyExtTests {

    private func extBytes(incompat: UInt32 = 0, compat: UInt32 = 0, size: Int = 0x9000) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: size)
        let sb = 1024
        // incompat at sb+0x60
        b[sb+0x60] = UInt8(incompat & 0xFF)
        b[sb+0x61] = UInt8((incompat >> 8) & 0xFF)
        b[sb+0x62] = UInt8((incompat >> 16) & 0xFF)
        b[sb+0x63] = UInt8((incompat >> 24) & 0xFF)
        // compat at sb+0x5C
        b[sb+0x5C] = UInt8(compat & 0xFF)
        b[sb+0x5D] = UInt8((compat >> 8) & 0xFF)
        b[sb+0x5E] = UInt8((compat >> 16) & 0xFF)
        b[sb+0x5F] = UInt8((compat >> 24) & 0xFF)
        return b
    }

    @Test func returnsExt2WhenBufferTooShort() {
        // Superblock truncated — must not crash, must default to ext2.
        #expect(SwiftPartitionProbe.classifyExt([UInt8](repeating: 0, count: 100)) == "ext2")
    }

    @Test func noFlagsIsExt2() {
        #expect(SwiftPartitionProbe.classifyExt(extBytes()) == "ext2")
    }

    @Test func hasJournalCompatFlagIsExt3() {
        #expect(SwiftPartitionProbe.classifyExt(extBytes(compat: 0x0004)) == "ext3")
    }

    @Test func extentsIncompatFlagIsExt4() {
        #expect(SwiftPartitionProbe.classifyExt(extBytes(incompat: 0x1000)) == "ext4")
    }

    @Test func allExt4IncompatFlagsTriggersExt4() {
        let allFlags: UInt32 = 0x0040|0x0080|0x0100|0x0200|0x1000|0x2000|0x4000|0x8000
        #expect(SwiftPartitionProbe.classifyExt(extBytes(incompat: allFlags)) == "ext4")
    }
}
