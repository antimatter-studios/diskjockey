import Foundation

/// Native Swift partition-table probe. Reads directly from the URL
/// (respects security-scoped access — no subprocess), so it works even in
/// the MAS sandbox where a child process can't open a file the parent got
/// via drag-and-drop or the Open panel.
///
/// Handles raw .img / .dd files (MBR and GPT). Container formats (QCOW2,
/// VHD, VHDX, VMDK) are not decompressed here — fall back to diskprobe
/// for those.
enum SwiftPartitionProbe {

    // MARK: - Top-level entry point

    /// Probe `url`. Returns nil if the file can't be read or is clearly a
    /// container format that needs diskprobe.
    static func probe(at url: URL) -> DiskProbeResult? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // Read the first sector.
        guard let sector0 = try? handle.read(upToCount: 512),
              sector0.count >= 512 else { return nil }

        let fileSize = Self.fileSize(url: url)

        // Skip known container formats — diskprobe handles those.
        if isContainerFormat(sector0: sector0, handle: handle, fileSize: fileSize) { return nil }

        // GPT: signature "EFI PART" at LBA 1 bytes 0-8.
        if let sector1 = try? readBytes(handle: handle, at: 512, count: 512),
           sector1.prefix(8).elementsEqual("EFI PART".utf8) {
            let parts = parseGPT(handle: handle, header: sector1)
            return DiskProbeResult(
                path: url.path,
                container: "raw",
                containerSizeBytes: fileSize,
                table: "gpt",
                deviceFsKind: nil,
                partitions: parts
            )
        }

        // MBR: boot signature 0x55 0xAA at bytes 510-511.
        if sector0[510] == 0x55 && sector0[511] == 0xAA {
            // Protective MBR (single 0xEE entry) means GPT was supposed to be
            // here but the GPT header is missing or unreadable — treat as none.
            let parts = parseMBR(sector0: sector0, handle: handle)
            if !parts.isEmpty {
                return DiskProbeResult(
                    path: url.path,
                    container: "raw",
                    containerSizeBytes: fileSize,
                    table: "mbr",
                    deviceFsKind: nil,
                    partitions: parts
                )
            }
        }

        // No partition table — sniff the whole device.
        let fsKind = sniffFS(handle: handle, at: 0, maxBytes: min(fileSize, 0x9000))
        return DiskProbeResult(
            path: url.path,
            container: "raw",
            containerSizeBytes: fileSize,
            table: "none",
            deviceFsKind: fsKind == "unknown" ? nil : fsKind,
            partitions: []
        )
    }

    // MARK: - Container detection

    private static func isContainerFormat(sector0: Data, handle: FileHandle, fileSize: UInt64) -> Bool {
        // QCOW2
        if sector0.prefix(4).elementsEqual([0x51, 0x46, 0x49, 0xFB]) { return true }
        // VHDX
        if sector0.prefix(8).elementsEqual("vhdxfile".utf8) { return true }
        // VMDK
        if sector0.prefix(4).elementsEqual("KDMV".utf8) { return true }
        // Dynamic VHD header at offset 0
        if sector0.prefix(8).elementsEqual("conectix".utf8) { return true }
        // Fixed VHD footer at file end
        if fileSize >= 512,
           let footer = try? readBytes(handle: handle, at: fileSize - 512, count: 8),
           footer.elementsEqual("conectix".utf8) { return true }
        return false
    }

    // MARK: - MBR parsing

    private static func parseMBR(sector0: Data, handle: FileHandle) -> [DiskProbeResult.Partition] {
        var parts: [DiskProbeResult.Partition] = []
        for i in 0..<4 {
            let entry = sector0[(446 + i * 16)...]
            let typeCode = entry[entry.startIndex + 4]
            // Skip empty, extended, and GPT-protective entries.
            guard typeCode != 0x00,
                  typeCode != 0x05, typeCode != 0x0F, typeCode != 0x85,
                  typeCode != 0xEE else { continue }

            let lbaStart = UInt64(le32(entry, offset: 8))
            let lbaCount = UInt64(le32(entry, offset: 12))
            guard lbaStart > 0, lbaCount > 0 else { continue }

            let byteStart  = lbaStart * 512
            let byteLength = lbaCount * 512

            let fsKind = sniffFS(handle: handle, at: byteStart, maxBytes: min(byteLength, 0x9000))
            let resolved = resolveTypeCode(typeCode, sniffed: fsKind)

            parts.append(DiskProbeResult.Partition(
                index: i,
                start: byteStart,
                length: byteLength,
                fsKind: resolved,
                typeByte: Int(typeCode),
                typeGuid: "00000000-0000-0000-0000-000000000000",
                label: nil
            ))
        }
        return parts
    }

    // MARK: - GPT parsing

    private static func parseGPT(handle: FileHandle, header: Data) -> [DiskProbeResult.Partition] {
        guard header.count >= 92 else { return [] }
        let entryStartLBA = le64(header, offset: 72)
        let entryCount    = UInt64(le32(header, offset: 80))
        let entrySize     = UInt64(le32(header, offset: 84))
        guard entrySize >= 128, entryCount > 0, entryCount <= 256 else { return [] }

        var parts: [DiskProbeResult.Partition] = []
        for i in 0..<entryCount {
            let entryOffset = (entryStartLBA * 512) + i * entrySize
            guard let entry = try? readBytes(handle: handle, at: entryOffset, count: Int(entrySize)),
                  entry.count >= 56 else { continue }

            // Type GUID (first 16 bytes). All-zeros = unused entry.
            let typeBytes = Data(entry[0..<16])
            guard typeBytes.contains(where: { $0 != 0 }) else { continue }

            let partStart  = le64(entry, offset: 32) * 512
            let partEnd    = le64(entry, offset: 40) * 512
            guard partEnd > partStart else { continue }
            let partLength = partEnd - partStart + 512

            let typeGuid = formatGPTGUID(typeBytes)

            // Partition name (UTF-16LE at offset 56, up to 72 bytes = 36 chars)
            let nameData = Data(entry[56..<min(entry.count, 128)])
            let label = String(bytes: nameData, encoding: .utf16LittleEndian)?
                .trimmingCharacters(in: .init(charactersIn: "\0"))
                .trimmingCharacters(in: .whitespaces)

            let fsKind = sniffFS(handle: handle, at: partStart, maxBytes: min(partLength, 0x9000))
            let resolved = resolveGPTType(typeGuid, sniffed: fsKind)

            parts.append(DiskProbeResult.Partition(
                index: parts.count,
                start: partStart,
                length: partLength,
                fsKind: resolved,
                typeByte: 0,
                typeGuid: typeGuid,
                label: label?.isEmpty == true ? nil : label
            ))
        }
        return parts
    }

    // MARK: - Filesystem sniffing

    static func sniffFS(handle: FileHandle, at offset: UInt64, maxBytes: UInt64) -> String {
        guard let buf = try? readBytes(handle: handle, at: offset, count: Int(min(maxBytes, 0x9000))),
              !buf.isEmpty else { return "unknown" }
        return classify(buf)
    }

    private static func classify(_ buf: Data) -> String {
        let b = Array(buf)
        // SquashFS
        if b.count >= 4 && b[0...3] == [0x68, 0x73, 0x71, 0x73] { return "squashfs" }

        // FAT / NTFS / exFAT: boot sector with 0x55 0xAA signature
        if b.count >= 512 && b[510] == 0x55 && b[511] == 0xAA {
            if b.count >= 11 && Data(b[3..<11]) == Data("NTFS    ".utf8)  { return "ntfs" }
            if b.count >= 11 && Data(b[3..<11]) == Data("EXFAT   ".utf8)  { return "exfat" }
            if b.count >= 0x5A && Data(b[0x52..<0x5A]) == Data("FAT32   ".utf8) { return "fat32" }
            if b.count >= 0x3E && (Data(b[0x36..<0x3E]) == Data("FAT16   ".utf8) ||
                                   Data(b[0x36..<0x3E]) == Data("FAT12   ".utf8)) { return "fat16" }
        }

        // ext2/3/4: superblock magic 0xEF53 at byte 1080
        if b.count >= 1082 {
            let magic = UInt16(b[1080]) | (UInt16(b[1081]) << 8)
            if magic == 0xEF53 { return classifyExt(b) }
        }

        // HFS+: 'H+' or 'HX' at offset 1024
        if b.count >= 1026 && (Data(b[1024..<1026]) == Data("H+".utf8) ||
                                Data(b[1024..<1026]) == Data("HX".utf8)) { return "hfs_plus" }

        // APFS: 'NXSB' at offset 32
        if b.count >= 36 && Data(b[32..<36]) == Data("NXSB".utf8) { return "apfs" }

        // Linux swap
        for page in [4096, 8192, 16384, 32768, 65536] {
            if b.count >= page && Data(b[(page-10)..<page]) == Data("SWAPSPACE2".utf8) {
                return "linux_swap"
            }
        }

        // ISO 9660
        if b.count >= 0x8006 && Data(b[0x8001..<0x8006]) == Data("CD001".utf8) { return "iso9660" }

        return "unknown"
    }

    private static func classifyExt(_ b: [UInt8]) -> String {
        guard b.count >= 1024 + 0x68 else { return "ext2" }
        let sb = 1024
        let incompat = UInt32(b[sb+0x60]) | (UInt32(b[sb+0x61]) << 8) |
                       (UInt32(b[sb+0x62]) << 16) | (UInt32(b[sb+0x63]) << 24)
        let compat   = UInt32(b[sb+0x5C]) | (UInt32(b[sb+0x5D]) << 8) |
                       (UInt32(b[sb+0x5E]) << 16) | (UInt32(b[sb+0x5F]) << 24)
        let ext4mask: UInt32 = 0x040|0x080|0x100|0x200|0x400|0x1000|0x2000|0x4000|0x8000
        if incompat & ext4mask != 0 { return "ext4" }
        if compat & 0x4 != 0 { return "ext3" }
        return "ext2"
    }

    // MARK: - Type resolution

    private static func resolveTypeCode(_ code: UInt8, sniffed: String) -> String {
        switch code {
        case 0x82: return "linux_swap"
        case 0x83: return sniffed != "unknown" ? sniffed : "ext4"
        case 0x0B, 0x0C, 0x1B, 0x1C: return "fat32"
        case 0x01, 0x04, 0x06, 0x0E, 0x14, 0x16, 0x1E: return "fat16"
        case 0x07: return sniffed != "unknown" ? sniffed : "ntfs"
        case 0xAF: return sniffed != "unknown" ? sniffed : "hfs_plus"
        default: return sniffed != "unknown" ? sniffed : "unknown"
        }
    }

    private static func resolveGPTType(_ guid: String, sniffed: String) -> String {
        // Well-known GPT type GUIDs.
        switch guid.lowercased() {
        case "0fc63daf-8483-4772-8e79-3d69d8477de4": // Linux filesystem data
            return sniffed != "unknown" ? sniffed : "ext4"
        case "e3c9e316-0b5c-4db8-817d-f92df00215ae": // Windows Basic Data (NTFS/FAT)
            return sniffed != "unknown" ? sniffed : "ntfs"
        case "c12a7328-f81f-11d2-ba4b-00a0c93ec93b": // EFI System
            return sniffed != "unknown" ? sniffed : "fat32"
        case "0657fd6d-a4ab-43c4-84e5-0933c84b4f4f": // Linux swap
            return "linux_swap"
        case "21686148-6449-6e6f-744e-656564454649": // BIOS boot
            return "unknown"
        default:
            return sniffed != "unknown" ? sniffed : "unknown"
        }
    }

    // MARK: - Low-level helpers

    private static func readBytes(handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count) else { return Data() }
        return data
    }

    private static func fileSize(url: URL) -> UInt64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
    }

    private static func le32(_ data: Data, offset: Int) -> UInt32 {
        let s = data.index(data.startIndex, offsetBy: offset)
        return UInt32(data[s]) |
               (UInt32(data[s+1]) << 8) |
               (UInt32(data[s+2]) << 16) |
               (UInt32(data[s+3]) << 24)
    }

    private static func le64(_ data: Data, offset: Int) -> UInt64 {
        let s = data.index(data.startIndex, offsetBy: offset)
        return UInt64(data[s]) |
               (UInt64(data[s+1]) << 8) |
               (UInt64(data[s+2]) << 16) |
               (UInt64(data[s+3]) << 24) |
               (UInt64(data[s+4]) << 32) |
               (UInt64(data[s+5]) << 40) |
               (UInt64(data[s+6]) << 48) |
               (UInt64(data[s+7]) << 56)
    }

    private static func formatGPTGUID(_ bytes: Data) -> String {
        // GPT GUID: first 3 groups are little-endian, last 2 are big-endian.
        guard bytes.count >= 16 else { return "00000000-0000-0000-0000-000000000000" }
        let b = Array(bytes)
        let d1 = UInt32(b[0]) | (UInt32(b[1])<<8) | (UInt32(b[2])<<16) | (UInt32(b[3])<<24)
        let d2 = UInt16(b[4]) | (UInt16(b[5])<<8)
        let d3 = UInt16(b[6]) | (UInt16(b[7])<<8)
        return String(format: "%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                      d1, d2, d3, b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
    }
}
