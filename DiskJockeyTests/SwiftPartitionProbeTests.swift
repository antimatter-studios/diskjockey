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

    @Test func eaInodeIncompatFlagIsExt4() {
        #expect(SwiftPartitionProbe.classifyExt(extBytes(incompat: 0x0400)) == "ext4")
    }

    @Test func allExt4IncompatFlagsTriggersExt4() {
        let allFlags: UInt32 = 0x0040|0x0080|0x0100|0x0200|0x0400|0x1000|0x2000|0x4000|0x8000
        #expect(SwiftPartitionProbe.classifyExt(extBytes(incompat: allFlags)) == "ext4")
    }
}

// MARK: - parseGPT overflow tests

/// A GPT header, and every partition entry inside it, carries LBA values with
/// no upper bound. Turning one into a byte offset is a multiply, and Swift
/// traps on integer overflow in **every** build configuration — Release
/// included — so before these guards a corrupt or crafted image terminated the
/// app the moment Disk Inspector probed it.
///
/// Each malformed image below is built so that the overflowing value *wraps
/// onto a real partition entry*. That matters: the guards use
/// `multipliedReportingOverflow`/`addingReportingOverflow`, which wrap
/// silently rather than trapping, so an image whose wrapped offset pointed at
/// nothing would read back as "no partitions" whether the guard was there or
/// not. Landing the wrap on a valid entry makes the guard's presence
/// observable — unguarded yields a partition, guarded yields none.
struct GPTOverflowTests {

    /// UInt64.max / 512 — the largest LBA whose byte offset is representable.
    static let maxSafeLBA = UInt64.max / 512          // 0x1FF_FFFF_FFFF_FFFF
    /// `lba * 512` overflows and wraps to exactly 1024: any lba ≡ 2 (mod 2^55).
    static let wrapsTo1024: UInt64 = (1 << 55) + 2
    /// Same shape, wrapping to 2048.
    static let wrapsTo2048: UInt64 = (1 << 55) + 4

    /// A well-formed entry at LBA 34-40 → start 17408, length 3584.
    static let goodEntryStart: UInt64 = 34 * 512
    static let goodEntryLength: UInt64 = (40 - 34) * 512 + 512

    private struct Entry {
        let at: Int             // byte offset of the entry within the image
        let firstLBA: UInt64
        let lastLBA: UInt64
    }

    /// Build a raw GPT image. Header fields are written verbatim so a hostile
    /// value can be injected, and entries are placed at explicit byte offsets
    /// so a wrap has something to land on.
    private func gptImage(entryTableLBA: UInt64,
                          entryCount: UInt32,
                          entrySize: UInt32,
                          entries: [Entry],
                          sectors: Int = 64) -> Data {
        var d = Data(count: sectors * 512)
        func le(_ v: UInt64, _ n: Int, at off: Int) {
            for k in 0..<n { d[off + k] = UInt8((v >> (8 * UInt64(k))) & 0xFF) }
        }
        let h = 512                                    // LBA 1 = GPT header
        d.replaceSubrange(h..<(h + 8), with: Array("EFI PART".utf8))
        le(entryTableLBA, 8, at: h + 72)
        le(UInt64(entryCount), 4, at: h + 80)
        le(UInt64(entrySize), 4, at: h + 84)
        for e in entries {
            d[e.at] = 0xAB                             // non-zero type GUID
            le(e.firstLBA, 8, at: e.at + 32)
            le(e.lastLBA, 8, at: e.at + 40)
        }
        return d
    }

    /// Per-pid-and-counter fixture name — never a fixed one, so tests running
    /// in parallel and concurrent runs of the suite can't collide on a path.
    private static let counterLock = NSLock()
    private static var counter = 0
    private func writeImage(_ d: Data) throws -> URL {
        Self.counterLock.lock()
        Self.counter += 1
        let n = Self.counter
        Self.counterLock.unlock()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dj-gpt-overflow-\(getpid())-\(n).img")
        try d.write(to: url)
        return url
    }

    /// Probe an image, then delete it.
    private func probe(_ d: Data) throws -> DiskProbeResult? {
        let url = try writeImage(d)
        defer { try? FileManager.default.removeItem(at: url) }
        return SwiftPartitionProbe.probe(at: url)
    }

    // MARK: The five overflow sites

    @Test func entryTableLBATooLargeYieldsNoPartitions() throws {
        // entryStartLBA * 512 overflows, wrapping onto the entry at byte 1024.
        let r = try probe(gptImage(entryTableLBA: Self.wrapsTo1024,
                                   entryCount: 1, entrySize: 128,
                                   entries: [Entry(at: 1024, firstLBA: 34, lastLBA: 40)]))
        #expect(r?.table == "gpt")
        #expect(r?.partitions.isEmpty == true)
    }

    @Test func entryOffsetSumOverflowSkipsEntry() throws {
        // tableStart is exactly representable; tableStart + 1*512 overflows
        // and wraps to 0, where a real entry sits.
        let r = try probe(gptImage(entryTableLBA: Self.maxSafeLBA,
                                   entryCount: 2, entrySize: 512,
                                   entries: [Entry(at: 0, firstLBA: 34, lastLBA: 40)]))
        #expect(r?.table == "gpt")
        #expect(r?.partitions.isEmpty == true)
    }

    @Test func partitionFirstLBATooLargeSkipsEntry() throws {
        // firstLBA * 512 overflows, wrapping to 1024 — under the 2048 partEnd,
        // so an unguarded wrap would satisfy `partEnd > partStart`.
        let r = try probe(gptImage(entryTableLBA: 2, entryCount: 1, entrySize: 128,
                                   entries: [Entry(at: 1024,
                                                   firstLBA: Self.wrapsTo1024,
                                                   lastLBA: 4)]))
        #expect(r?.partitions.isEmpty == true)
    }

    @Test func partitionLastLBATooLargeSkipsEntry() throws {
        // lastLBA * 512 overflows, wrapping to 2048 — over the 1024 partStart.
        let r = try probe(gptImage(entryTableLBA: 2, entryCount: 1, entrySize: 128,
                                   entries: [Entry(at: 1024,
                                                   firstLBA: 2,
                                                   lastLBA: Self.wrapsTo2048)]))
        #expect(r?.partitions.isEmpty == true)
    }

    @Test func partitionLengthOverflowSkipsEntry() throws {
        // Both multiplies fit. GPT's last-LBA is inclusive, so the span is the
        // difference plus one sector, and that last sector is what overflows:
        // an unguarded wrap reports a partition of length 0.
        let r = try probe(gptImage(entryTableLBA: 2, entryCount: 1, entrySize: 128,
                                   entries: [Entry(at: 1024,
                                                   firstLBA: 0,
                                                   lastLBA: Self.maxSafeLBA)]))
        #expect(r?.partitions.isEmpty == true)
    }

    // MARK: Scope of the rejection

    @Test func oneBadEntryDoesNotDiscardTheGoodOnes() throws {
        // An unrepresentable entry is dropped on its own; the rest of an
        // otherwise-parseable table still yields its partitions.
        let r = try probe(gptImage(entryTableLBA: 2, entryCount: 2, entrySize: 128,
                                   entries: [Entry(at: 1024,
                                                   firstLBA: 2,
                                                   lastLBA: Self.wrapsTo2048),
                                             Entry(at: 1152, firstLBA: 34, lastLBA: 40)]))
        #expect(r?.partitions.count == 1)
        #expect(r?.partitions.first?.start == Self.goodEntryStart)
        #expect(r?.partitions.first?.length == Self.goodEntryLength)
    }

    @Test func wellFormedGPTStillParses() throws {
        // The control: without this, every assertion above could be satisfied
        // by a probe that rejects all GPTs.
        let r = try probe(gptImage(entryTableLBA: 2, entryCount: 1, entrySize: 128,
                                   entries: [Entry(at: 1024, firstLBA: 34, lastLBA: 40)]))
        #expect(r?.table == "gpt")
        #expect(r?.partitions.count == 1)
        #expect(r?.partitions.first?.start == Self.goodEntryStart)
        #expect(r?.partitions.first?.length == Self.goodEntryLength)
    }
}
