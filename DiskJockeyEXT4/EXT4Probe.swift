/*
 * EXT4Probe.swift — FSKit `probeResource` pipeline.
 *
 * Two entry points the framework dispatches into based on resource
 * kind:
 *   • `probeResource(resource:replyHandler:)` for `FSBlockDeviceResource`
 *     (the normal "plug a disk in" path).
 *   • `probeFileResource(_:replyHandler:)` for `FSPathURLResource`
 *     (the file-backed mount path, e.g. `mount -t ext4 disk.img`).
 *
 * Both run the same logical pipeline: try the known disk-image
 * container magics at offset 0 (and the conectix footer for fixed
 * VHD), fall back to a raw ext4 superblock check at offset 1024.
 *
 * `ContainerKind` and the cross-resource-kind `detectContainer<C>`
 * primitive live here too — they're probe-side concepts (matching
 * magic bytes) even though `loadResource` ultimately consumes the
 * detection result. EXT4Load.swift accesses them as
 * `EXT4FileSystem.ContainerKind` / `Self.detectContainer(...)`.
 */

import FSKit
import Foundation
import DiskJockeyLibrary

extension EXT4FileSystem {

    // MARK: - probeResource

    func probeResource(
        resource: FSResource,
        replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        log.info("probe called", scope: AppLogScope.probe)

        if let fileResource = resource as? FSPathURLResource {
            probeFileResource(fileResource, replyHandler: replyHandler)
            return
        }

        guard let blockDevice = resource as? FSBlockDeviceResource else {
            log.warn("probe: unsupported resource type — not recognized", scope: AppLogScope.probe)
            replyHandler(.notRecognized, nil)
            return
        }
        // All subsequent log lines in this probe carry `fields["bsd"]`
        // so the host app routes them into the matching partition's
        // per-disk log strip. `scope: probe` puts them in the
        // detection bucket for both system + per-mount denylists.
        let dlog = TaggedLogger(
            log, fields: ["bsd": blockDevice.bsdName], kind: "ext4.probe",
            scope: AppLogScope.probe
        )
        dlog.info("probe \(blockDevice.bsdName): blockSize=\(blockDevice.blockSize) blockCount=\(blockDevice.blockCount)")

        do {
            var buf = [UInt8](repeating: 0, count: 1024)
            let bytesRead = try buf.withUnsafeMutableBytes { rawBuf in
                try blockDevice.read(into: rawBuf, startingAt: 1024, length: 1024)
            }

            guard bytesRead >= 58 else {
                dlog.info("probe: read \(bytesRead) bytes (< 58) — not ext4")
                replyHandler(.notRecognized, nil)
                return
            }

            let magic = UInt16(buf[56]) | (UInt16(buf[57]) << 8)
            guard magic == 0xEF53 else {
                dlog.info("probe: superblock magic mismatch (0x\(String(magic, radix: 16))) — not ext4")
                replyHandler(.notRecognized, nil)
                return
            }

            let nameBytes = buf[120..<136]
            let rawName = String(bytes: nameBytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
            let volumeName = rawName.isEmpty ? "ext4" : rawName
            let uuidBytes = Array(buf[104..<120])
            let containerID = FSContainerIdentifier(uuid: NSUUID(uuidBytes: uuidBytes) as UUID)
            dlog.info("probe: recognized ext4 volume \"\(volumeName)\"")

            replyHandler(.usable(name: volumeName, containerID: containerID), nil)
        } catch {
            dlog.error("probe: block-device read failed — \(error.localizedDescription)")
            replyHandler(.notRecognized, nil)
        }
    }

    // MARK: - File resource (FSPathURLResource) probe

    fileprivate func probeFileResource(
        _ resource: FSPathURLResource,
        replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        let url = resource.url
        let dlog = TaggedLogger(log, fields: ["file": url.lastPathComponent],
                                kind: "ext4.probe", scope: AppLogScope.probe)
        dlog.info("probe FSPathURLResource: \(url.path)")

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else {
            dlog.warn("probe: cannot open file (errno=\(errno)) — not recognized")
            replyHandler(.notRecognized, nil)
            return
        }
        defer { Darwin.close(fd) }

        // Check for known container magic at offset 0
        var hdr = [UInt8](repeating: 0, count: 16)
        let n = hdr.withUnsafeMutableBufferPointer { buf in pread(fd, buf.baseAddress!, 16, 0) }
        if n >= 8 {
            if Array(hdr.prefix(4)) == ContainerKind.qcow2Magic {
                dlog.info("probe: qcow2 container → usable as ext4")
                replyHandler(.usable(name: "ext4", containerID: FSContainerIdentifier(uuid: UUID())), nil)
                return
            }
            if Array(hdr.prefix(8)) == ContainerKind.vhdxMagic {
                dlog.info("probe: vhdx container → usable as ext4")
                replyHandler(.usable(name: "ext4", containerID: FSContainerIdentifier(uuid: UUID())), nil)
                return
            }
            if Array(hdr.prefix(8)) == ContainerKind.conectixMagic {
                dlog.info("probe: vhd (dynamic) → usable as ext4")
                replyHandler(.usable(name: "ext4", containerID: FSContainerIdentifier(uuid: UUID())), nil)
                return
            }
            if Array(hdr.prefix(4)) == ContainerKind.vmdkMagic {
                dlog.info("probe: vmdk container → usable as ext4")
                replyHandler(.usable(name: "ext4", containerID: FSContainerIdentifier(uuid: UUID())), nil)
                return
            }
        }

        // Fixed VHD: "conectix" in the last vhdFixedFooterOffset bytes
        var st = Darwin.stat()
        if Darwin.fstat(fd, &st) == 0 && st.st_size >= ContainerKind.vhdFixedFooterOffset {
            var footer = [UInt8](repeating: 0, count: 8)
            let fr = footer.withUnsafeMutableBufferPointer { buf in
                pread(fd, buf.baseAddress!, 8, off_t(st.st_size) - off_t(ContainerKind.vhdFixedFooterOffset))
            }
            if fr == 8 && footer == ContainerKind.conectixMagic {
                dlog.info("probe: vhd (fixed) footer → usable as ext4")
                replyHandler(.usable(name: "ext4", containerID: FSContainerIdentifier(uuid: UUID())), nil)
                return
            }
        }

        // Raw ext4 superblock at offset 1024 (need 136 bytes for name + UUID)
        var sb = [UInt8](repeating: 0, count: 136)
        let nr = sb.withUnsafeMutableBufferPointer { buf in pread(fd, buf.baseAddress!, 136, 1024) }
        guard nr >= 58 else {
            dlog.info("probe: file too small for ext4 superblock — not recognized")
            replyHandler(.notRecognized, nil)
            return
        }
        let magic = UInt16(sb[56]) | (UInt16(sb[57]) << 8)
        guard magic == 0xEF53 else {
            dlog.info("probe: no ext4 magic or known container — not recognized")
            replyHandler(.notRecognized, nil)
            return
        }
        let rawName = String(bytes: sb[120..<136].prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
        let volumeName = rawName.isEmpty ? "ext4" : rawName
        let uuidBytes = Array(sb[104..<120])
        let containerID = FSContainerIdentifier(uuid: NSUUID(uuidBytes: uuidBytes) as UUID)
        dlog.info("probe: raw ext4 superblock in file — volume \"\(volumeName)\"")
        replyHandler(.usable(name: volumeName, containerID: containerID), nil)
    }

    // MARK: - Container detection

    /// Disk-image container kinds we know how to unwrap onto an
    /// FsCoreDevice before mounting ext4 on the resulting virtual
    /// device. Mirrored on the NTFS side (NTFSFileSystem.swift).
    enum ContainerKind: String, CustomStringConvertible {
        case qcow2, vhd, vhdx, vmdk
        var description: String { rawValue }

        static let qcow2Magic: [UInt8]    = [0x51, 0x46, 0x49, 0xFB]              // "QFI\xFB"
        static let vhdxMagic: [UInt8]    = [0x76, 0x68, 0x64, 0x78,
                                             0x66, 0x69, 0x6c, 0x65]             // "vhdxfile"
        static let vmdkMagic: [UInt8]    = [0x4b, 0x44, 0x4d, 0x56]             // "KDMV" (LE "VMDK")
        static let conectixMagic: [UInt8] = [0x63, 0x6f, 0x6e, 0x65,
                                              0x63, 0x74, 0x69, 0x78]            // "conectix" VHD footer
        /// Fixed VHD format places the conectix footer in the last 512 bytes.
        static let vhdFixedFooterOffset: Int = 512
    }

    /// Probe for a known container magic using any DeviceReadable context.
    /// Returns nil for raw partition images (fs_ext4 handles those directly).
    static func detectContainer<C: DeviceReadable>(context: C, sizeBytes: UInt64) -> ContainerKind? {
        var head = [UInt8](repeating: 0, count: 16)
        let rc = head.withUnsafeMutableBufferPointer { buf -> Int32 in
            context.read(into: buf.baseAddress!, offset: 0, length: 16)
        }
        if rc == 0 {
            if Array(head.prefix(4)) == ContainerKind.qcow2Magic   { return .qcow2 }
            if Array(head.prefix(8)) == ContainerKind.vhdxMagic    { return .vhdx }
            if Array(head.prefix(4)) == ContainerKind.vmdkMagic    { return .vmdk }
            if Array(head.prefix(8)) == ContainerKind.conectixMagic { return .vhd }
        }
        if sizeBytes >= ContainerKind.vhdFixedFooterOffset {
            var footer = [UInt8](repeating: 0, count: 8)
            let frc = footer.withUnsafeMutableBufferPointer { buf -> Int32 in
                context.read(into: buf.baseAddress!, offset: off_t(sizeBytes) - off_t(ContainerKind.vhdFixedFooterOffset), length: 8)
            }
            if frc == 0 && footer == ContainerKind.conectixMagic { return .vhd }
        }
        return nil
    }
}
