import Foundation
import AppKit
import OSLog
import DiskArbitration
import DiskJockeyLibrary

/// Mounts ext4 images / block devices via macOS 26's `mount -F` path, which
/// routes to fskitd without the `com.apple.developer.fskit.fsclient`
/// entitlement. Companion to `MountManager` (File Provider) — FSKit
/// extensions live in their own lane because they bypass NSFileProvider
/// entirely.
///
/// The bundled DiskJockeyEXT4 FSKit extension must be registered with
/// pluginkit (which happens automatically once the host app has launched
/// at least once with the embedded .appex in place).
/// JSON shape emitted by the staged `diskprobe` CLI binary. Mirrors the
/// schema the binary documents in its own usage block. Codable keys map
/// to snake_case JSON via a custom CodingKeys table.
struct DiskProbeResult: Decodable {
    let path: String
    let container: String
    let containerSizeBytes: UInt64
    let table: String   // "gpt" | "mbr" | "none"
    /// Only present when `table == "none"` — filesystem type of the whole
    /// device when no partition table was found (e.g. a single-FS image).
    let deviceFsKind: String?
    let partitions: [Partition]

    struct Partition: Decodable {
        let index: Int
        let start: UInt64
        let length: UInt64
        let fsKind: String  // "ext4" | "ntfs" | "fat32" | "exfat" | "fat16" | "hfs_plus" | "apfs" | "linux_swap" | "iso9660" | "squashfs" | "unknown"
        let typeByte: Int
        let typeGuid: String
        let label: String?

        enum CodingKeys: String, CodingKey {
            case index, start, length, label
            case fsKind = "fs_kind"
            case typeByte = "type_byte"
            case typeGuid = "type_guid"
        }
    }

    enum CodingKeys: String, CodingKey {
        case path, container, table, partitions
        case containerSizeBytes = "container_size_bytes"
        case deviceFsKind = "device_fs_kind"
    }
}

@MainActor
final class FSKitMountService {
    static let shared = FSKitMountService()

    private let logger = Logger(subsystem: "com.antimatterstudios.diskjockey", category: "FSKitMount")

    enum FSKitError: LocalizedError {
        case processFailed(exitCode: Int32, stderr: String)
        case mountPointInUse(String)
        case invalidMountName(String)
        case authorizationDenied(stderr: String)

        var errorDescription: String? {
            switch self {
            case .processFailed(let code, let stderr):
                return "mount exited \(code): \(stderr)"
            case .mountPointInUse(let path):
                return "mount point \(path) already has a volume attached"
            case .invalidMountName(let name):
                return "invalid mount name \"\(name)\": must be non-empty and contain no slashes"
            case .authorizationDenied(let stderr):
                return "administrator authorization was denied or cancelled: \(stderr)"
            }
        }
    }

    // MARK: - Attach

    /// Mount an image or block device at `/Volumes/<name>` via FSKit.
    /// - Parameters:
    ///   - source: absolute path to a filesystem image or /dev/diskN node.
    ///   - name: volume name — becomes the mount point under /Volumes.
    ///   - fsType: FSKit short name (e.g. `ext4`, `ntfs`). Must correspond to
    ///     a registered FSModule the system can dispatch to.
    ///   - mountOptions: optional `-o` task-options string passed verbatim
    ///     to mount(8). Used for partition slicing (`partition_offset=N,
    ///     partition_length=M,container=K`); the matching extension reads
    ///     these via FSTaskOptions.taskOptions.
    func attach(imagePath source: String, name: String, fsType: String,
                mountOptions: String? = nil) async throws {
        try Self.validateMountName(name)

        // Block device path — use DA directly, no root needed.
        // diskarbitrationd handles privilege and invokes the appropriate
        // driver (Apple or FSKit extension) based on fs probing.
        if source.hasPrefix("/dev/") {
            guard let session = DASessionCreate(kCFAllocatorDefault) else {
                throw FSKitError.processFailed(exitCode: -1, stderr: "Failed to create DA session")
            }
            DASessionSetDispatchQueue(session, .global(qos: .userInitiated))
            logger.info("attach (DA) \(source, privacy: .public)")
            try await Self.mountSliceWithDA(source, session: session)
            return
        }

        logger.info("attach (hdiutil) \(fsType, privacy: .public) \(source, privacy: .public)")
        let hdiResult = try await Self.runHdiutilAttach(at: source)
        guard let daSession = DASessionCreate(kCFAllocatorDefault) else {
            _ = try? await Self.runHdiutilDetach(hdiResult.parentDevice)
            throw FSKitError.processFailed(exitCode: -1, stderr: "Failed to create DA session")
        }
        DASessionSetDispatchQueue(daSession, .global(qos: .userInitiated))
        // Mount slices if image has a partition table; otherwise mount the whole-disk device.
        let targets = hdiResult.slices.isEmpty ? [hdiResult.parentDevice] : hdiResult.slices
        var mountedCount = 0
        var lastError: Error?
        for target in targets {
            do {
                try await Self.mountSliceWithDA(target, session: daSession)
                mountedCount += 1
            } catch {
                logger.error("DA mount \(target, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                lastError = error
            }
        }
        if mountedCount == 0 {
            _ = try? await Self.runHdiutilDetach(hdiResult.parentDevice)
            throw lastError ?? FSKitError.processFailed(exitCode: -1, stderr: "All DA mounts failed")
        }
    }

    /// Multi-partition attach: probe the image's partition table, then
    /// mount every supported partition via Disk Arbitration (no root).
    /// diskarbitrationd handles the privileged mount(2) and invokes
    /// Apple drivers (FAT32/exFAT/HFS+/APFS) or our FSKit extensions
    /// (ext4/NTFS) depending on what probing discovers on each slice.
    ///
    /// For raw images: hdiutil attach turns the file into block devices,
    /// then DA mounts each slice. The fd-inheritance path (`imageURL`)
    /// lets hdiutil read the file via our in-process security-scoped
    /// access instead of needing its own open() permission.
    ///
    /// For container images (qcow2/vhd/vhdx/vmdk): Apple drivers need
    /// block devices and are skipped. Our FSKit extensions handle the
    /// container format internally.
    ///
    /// Returns the actual mount paths chosen by DA (based on volume label),
    /// which may differ from the mountPointPrefix-pN prediction.
    func attachAllPartitions(imagePath source: String,
                             imageURL: URL? = nil,
                             mountPointPrefix: String,
                             partitions: [DiskProbeResult.Partition],
                             container: String = "raw") async throws -> [String] {
        try Self.validateMountName(mountPointPrefix)

        let hdiutilCompatible = container == "raw" || container == "vhd" || container == "vmdk"

        struct Classified {
            var supported: [(part: DiskProbeResult.Partition, fs: String)] = []
            var skipped: [DiskProbeResult.Partition] = []
        }
        var c = Classified()
        for part in partitions {
            switch part.fsKind {
            case "ext4", "ext3", "ext2": c.supported.append((part, "ext4"))
            case "ntfs":                  c.supported.append((part, "ntfs"))
            case "fat32", "fat16":
                if hdiutilCompatible { c.supported.append((part, "msdos")) }
                else { c.skipped.append(part) }
            case "exfat":
                if hdiutilCompatible { c.supported.append((part, "exfat")) }
                else { c.skipped.append(part) }
            case "hfs_plus":
                if hdiutilCompatible { c.supported.append((part, "hfs")) }
                else { c.skipped.append(part) }
            case "apfs":
                if hdiutilCompatible { c.supported.append((part, "apfs")) }
                else { c.skipped.append(part) }
            default:                     c.skipped.append(part)
            }
        }
        for s in c.skipped {
            logger.info("skip partition \(s.index) (\(s.fsKind, privacy: .public)): no driver (container=\(container, privacy: .public))")
        }
        if c.supported.isEmpty { return [] }

        if hdiutilCompatible {
            // Attach image as block devices, then mount each slice via DA —
            // no root required. The fd-inheritance path avoids the sandbox
            // block that prevents hdiutil from opening security-scoped URLs.
            let hdiResult = try await Self.runHdiutilAttach(at: source, imageURL: imageURL)
            logger.info("hdiutil attach \(source, privacy: .public) -> \(hdiResult.parentDevice, privacy: .public) (\(hdiResult.slices.count, privacy: .public) slices)")

            var sliceByIndex: [Int: String] = [:]
            for slice in hdiResult.slices {
                if let n = Self.sliceNumber(of: slice) { sliceByIndex[n - 1] = slice }
            }

            guard let session = DASessionCreate(kCFAllocatorDefault) else {
                _ = try? await Self.runHdiutilDetach(hdiResult.parentDevice)
                throw FSKitError.processFailed(exitCode: -1, stderr: "Failed to create DA session")
            }
            DASessionSetDispatchQueue(session, .global(qos: .userInitiated))

            var mounted: [String] = []
            for (part, _) in c.supported {
                guard let slice = sliceByIndex[part.index] else {
                    logger.error("no hdiutil slice for partition \(part.index) (\(part.fsKind, privacy: .public))")
                    continue
                }
                do {
                    try await Self.mountSliceWithDA(slice, session: session)
                    let mp = Self.mountedPath(of: slice, session: session) ?? slice
                    logger.info("DA mounted \(slice, privacy: .public) -> \(mp, privacy: .public)")
                    mounted.append(mp)
                } catch {
                    logger.error("DA mount \(slice, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }

            if mounted.isEmpty {
                _ = try? await Self.runHdiutilDetach(hdiResult.parentDevice)
                logger.info("attachAllPartitions \(source, privacy: .public): all DA mounts failed")
            }
            return mounted
        }

        // Container formats (QCOW2/VHDX/VMDK) require a DriverKit block device
        // driver to mount — deferred to v2. The UI prevents users from reaching
        // this path (DiskImageInspectorView shows "coming in a future update").
        throw FSKitError.processFailed(exitCode: -1,
            stderr: "\(container.uppercased()): mounting requires a future update.")
    }

    /// hdiutil-attach result. The parent is the whole-disk node, slices
    /// are individual partition nodes (each is mountable via Apple's
    /// driver).
    struct HdiutilAttachResult {
        let parentDevice: String       // e.g. "/dev/disk5"
        let slices: [String]           // e.g. ["/dev/disk5s1", "/dev/disk5s2"]
    }

    static func runHdiutilAttach(at path: String, imageURL: URL? = nil) async throws -> HdiutilAttachResult {
        return try await DJAgentClient.shared.attachImage(atPath: path)
    }

    static func runHdiutilDetach(_ device: String) async throws {
        try await DJAgentClient.shared.detachDevice(device)
    }

    /// Extract the trailing slice number from a /dev/diskNsM path, or
    /// nil if the path doesn't match. Used to map hdiutil's slice list
    /// back to diskprobe's partition indices (s1 -> index 0, s2 -> 1, …).
    static func sliceNumber(of devEntry: String) -> Int? {
        guard let range = devEntry.range(of: #"s(\d+)$"#, options: .regularExpression) else {
            return nil
        }
        let digits = devEntry[range].dropFirst()
        return Int(digits)
    }

    // MARK: - Disk Arbitration helpers

    private final class DACallbackBox {
        let resume: (Error?) -> Void
        init(_ resume: @escaping (Error?) -> Void) { self.resume = resume }
    }

    /// Mount a block device via Disk Arbitration. diskarbitrationd runs as root
    /// and handles the privileged mount(2) call — the sandboxed app needs no
    /// elevated privileges. For FSKit-registered filesystems (ext4, NTFS) the
    /// daemon probes installed extensions and invokes the appropriate one.
    private static func mountSliceWithDA(_ bsdName: String, session: DASession) async throws {
        let devName = bsdName.hasPrefix("/dev/") ? String(bsdName.dropFirst(5)) : bsdName
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, devName) else {
            throw FSKitError.processFailed(exitCode: -1, stderr: "DA: no disk object for \(bsdName)")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let box = DACallbackBox { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            }
            let ptr = Unmanaged.passRetained(box).toOpaque()
            let cb: DADiskMountCallback = { (_, dissenter, ctx) in
                guard let ctx else { return }
                let b = Unmanaged<DACallbackBox>.fromOpaque(ctx).takeRetainedValue()
                if let d = dissenter {
                    let code = DADissenterGetStatus(d)
                    let msg = (DADissenterGetStatusString(d) as String?) ?? "DA error \(code)"
                    b.resume(FSKitError.processFailed(exitCode: code, stderr: msg))
                } else {
                    b.resume(nil)
                }
            }
            // Request a read-write mount explicitly. Without this, diskarbitrationd
            // treats disk images and removable media as read-only by default, which
            // causes FSBlockDeviceResource.isWritable to return false and the FSKit
            // extension to see a read-only resource.
            var args: [Unmanaged<CFString>?] = [Unmanaged.passRetained("rw" as CFString), nil]
            DADiskMountWithArguments(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), cb, ptr, &args)
            args[0]?.release()
        }
    }

    /// Query the mount path of an already-mounted block device from DA.
    private static func mountedPath(of bsdName: String, session: DASession) -> String? {
        let devName = bsdName.hasPrefix("/dev/") ? String(bsdName.dropFirst(5)) : bsdName
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, devName),
              let desc = DADiskCopyDescription(disk) as NSDictionary?,
              let url  = desc[kDADiskDescriptionVolumePathKey] as? URL else { return nil }
        return url.path
    }

    /// Run the staged diskprobe binary against `path` and return its
    /// JSON-decoded result. Throws if the binary is missing or fails.
    static func runDiskProbe(at path: String) throws -> DiskProbeResult {
        guard let probe = locateDiskProbeBinary() else {
            throw FSKitError.processFailed(exitCode: -1, stderr: "diskprobe binary not found in app bundle or lib/diskprobe/")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: probe)
        proc.arguments = [path]
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        if proc.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            throw FSKitError.processFailed(exitCode: proc.terminationStatus, stderr: err)
        }
        return try JSONDecoder().decode(DiskProbeResult.self, from: outData)
    }

    /// Find the diskprobe binary. Checks (in order):
    ///   1. App bundle Resources (the shipped path)
    ///   2. `lib/diskprobe/diskprobe` relative to the project root, by
    ///      walking up from this source file. Lets dev builds work
    ///      without an Xcode "Copy Files" build phase.
    private static func locateDiskProbeBinary() -> String? {
        if let url = Bundle.main.url(forResource: "diskprobe", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url.path
        }
        // Walk up from #filePath looking for "lib/diskprobe/diskprobe".
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("lib/diskprobe/diskprobe").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
            if dir.path == "/" { break }
        }
        return nil
    }

    // MARK: - Detach

    /// Unmount a volume under /Volumes via NSWorkspace. NSWorkspace routes
    /// through diskarbitrationd which handles the privileged umount(2) call
    /// — no root required in the sandboxed app.
    func detach(name: String) async throws {
        try Self.validateMountName(name)
        let url = URL(fileURLWithPath: "/Volumes/\(name)")
        logger.info("detach \(url.path, privacy: .public)")
        try NSWorkspace.shared.unmountAndEjectDevice(at: url)
    }

    // MARK: - Helpers

    private static func validateMountName(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("..") else {
            throw FSKitError.invalidMountName(name)
        }
    }

    private static func run(executable: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = Pipe()   // suppress stdout noise

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let msg = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(
                        throwing: FSKitError.processFailed(
                            exitCode: proc.terminationStatus,
                            stderr: msg.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

}

// MARK: - User-facing menu helper

@MainActor
enum FSKitAttachController {
    /// Opens a file picker for an ext4 image then triggers `attach`.
    /// Meant to be called from a menu item; runs async, surfaces errors via
    /// `NSAlert`.
    /// Prompt the user to pick an active mount under /Volumes and unmount it.
    static func promptAndDetach(logRepository: LogRepository? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Choose a volume to detach"
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Pick the /Volumes/<name> entry to unmount."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // /Volumes/<name> → just <name>.
        let name = url.lastPathComponent
        logRepository?.logFSKit("detach requested for /Volumes/\(name)", category: "info")
        Task { @MainActor in
            do {
                try await FSKitMountService.shared.detach(name: name)
                logRepository?.logFSKit("detached /Volumes/\(name)", category: "info")
                let ok = NSAlert()
                ok.messageText = "Detached /Volumes/\(name)"
                ok.runModal()
            } catch {
                logRepository?.logFSKit(
                    "detach /Volumes/\(name) failed: \(error.localizedDescription)",
                    category: "error")
                let fail = NSAlert(error: error)
                fail.runModal()
            }
        }
    }

    /// Container types we recognise wrapping a filesystem. The extension
    /// itself unwraps the container (peeks the same magic on its
    /// FSBlockDeviceResource and stacks the appropriate reader before
    /// handing the device down to the FS driver). Host only needs the
    /// label so we can prompt the user for the inner FS.
    enum DetectedContainer { case qcow2, vhd, vhdx, vmdk

        var label: String {
            switch self {
            case .qcow2: return "QCOW2"
            case .vhd:   return "VHD"
            case .vhdx:  return "VHDX"
            case .vmdk:  return "VMDK"
            }
        }
    }

    /// Probe the first KB or so of a file to identify which FSKit
    /// driver should mount it. Returns `(fsType, container)` —
    /// - `fsType` is a known FSKit short name ("ext4"/"ntfs") when the
    ///   filesystem is directly recognisable at offset 0;
    /// - `container` is set when the file is a known disk-image
    ///   wrapper (qcow2) and the inner filesystem can't be sniffed
    ///   from raw bytes.
    /// Both nil → unknown raw image, caller falls back to user pick.
    static func detectFSType(at url: URL) -> (fsType: String?, container: DetectedContainer?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? handle.close() }

        // Container detection at offset 0:
        //   QCOW2 — "QFI\xfb"     (51 46 49 fb)
        //   VHDX  — "vhdxfile"    (8 bytes)
        //   VMDK  — "KDMV"        (4 bytes; monolithicSparse)
        //   VHD   — footer-at-end with "conectix" cookie. Dynamic /
        //           differencing VHDs also have a footer COPY at offset
        //           0; fixed VHDs only have the trailing footer. Probing
        //           the trailing 512 covers all three modes.
        if let head = try? handle.read(upToCount: 16), head.count >= 11 {
            if head.count >= 4
                && head[0] == 0x51 && head[1] == 0x46
                && head[2] == 0x49 && head[3] == 0xFB {
                return (nil, .qcow2)
            }
            if head.count >= 8 && head.subdata(in: 0..<8) == Data("vhdxfile".utf8) {
                return (nil, .vhdx)
            }
            if head.count >= 4 && head.subdata(in: 0..<4) == Data("KDMV".utf8) {
                return (nil, .vmdk)
            }
            // Dynamic / differencing VHD: footer copy at offset 0 too.
            if head.count >= 8 && head.subdata(in: 0..<8) == Data("conectix".utf8) {
                return (nil, .vhd)
            }

            // NTFS: bytes [3, 11) of sector 0 are "NTFS    " (OEM ID).
            let oem = head.subdata(in: 3..<11)
            if oem == Data("NTFS    ".utf8) { return ("ntfs", nil) }
        }

        // Fixed VHD: footer at file_size - 512, cookie "conectix".
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = (attrs[.size] as? NSNumber)?.uint64Value, size >= 512 {
            do {
                try handle.seek(toOffset: size - 512)
                if let footer = try handle.read(upToCount: 8),
                   footer == Data("conectix".utf8) {
                    return (nil, .vhd)
                }
            } catch { /* fall through to ext4 probe */ }
        }

        // ext4: superblock magic 0xEF53 at byte offset 1080 (0x438),
        // little-endian.
        do {
            try handle.seek(toOffset: 1080)
            if let magic = try handle.read(upToCount: 2),
               magic.count == 2, magic[0] == 0x53, magic[1] == 0xEF {
                return ("ext4", nil)
            }
        } catch {
            return (nil, nil)
        }

        return (nil, nil)
    }

    /// Single entry point for "user pointed us at a disk image, mount
    /// it." Used by both the sidebar "Add Disk Image" button and the
    /// drag-and-drop handler. First probes the partition table via the
    /// staged diskprobe binary — if there's an MBR/GPT with supported
    /// partitions, mounts each one separately at /Volumes/<name>-pN.
    /// Falls back to whole-device mount when probe fails or finds no
    /// partition table.
    static func attachUserPickedImage(at url: URL, logRepository: LogRepository? = nil) {
        // Try diskprobe first — it handles containers (qcow2/vhd/vhdx/vmdk)
        // and raw images with MBR/GPT tables or a single filesystem.
        let probe: DiskProbeResult?
        do {
            probe = try FSKitMountService.runDiskProbe(at: url.path)
        } catch {
            logRepository?.logFSKit("diskprobe failed for \(url.lastPathComponent): \(error)", category: "warn")
            probe = nil
        }

        // Multi-partition path: MBR or GPT with at least one partition.
        if let probe, probe.table != "none", !probe.partitions.isEmpty {
            attachMultiPartition(url: url, probe: probe, logRepository: logRepository)
            return
        }

        // Single-FS path. Prefer diskprobe's whole-device sniff (sees through
        // container formats) then fall back to direct magic-byte detection.
        let detected = detectFSType(at: url)
        let resolvedFsType: String? = {
            if let kind = probe?.deviceFsKind, kind != "unknown" {
                switch kind {
                case "ext4", "ext3", "ext2": return "ext4"
                case "ntfs": return "ntfs"
                default: break
                }
            }
            return detected.fsType
        }()

        let fsType: String
        if let resolved = resolvedFsType {
            fsType = resolved
        } else {
            let pick = NSAlert()
            switch detected.container {
            case .some(let kind):
                pick.messageText = "\(kind.label) disk image detected"
                pick.informativeText = "\(url.lastPathComponent) is a \(kind.label) container. Pick the filesystem the guest formatted inside it (typically ext4 for Linux VMs, NTFS for Windows VMs)."
            case .none:
                pick.messageText = "Couldn't detect filesystem"
                pick.informativeText = "\(url.lastPathComponent) doesn't look like a raw ext4 or NTFS partition image. Pick a driver to try anyway, or cancel."
            }
            pick.addButton(withTitle: "Mount as ext4")
            pick.addButton(withTitle: "Mount as NTFS")
            pick.addButton(withTitle: "Cancel")
            switch pick.runModal() {
            case .alertFirstButtonReturn:  fsType = "ext4"
            case .alertSecondButtonReturn: fsType = "ntfs"
            default: return
            }
        }

        // DA mounts at the volume's own label — no need to ask the user for a name.
        let name = url.deletingPathExtension().lastPathComponent
        logRepository?.logFSKit(
            "attach (\(fsType)) requested: \(url.path) -> /Volumes/\(name)", category: "info")
        Task { @MainActor in
            do {
                try await FSKitMountService.shared.attach(
                    imagePath: url.path, name: name, fsType: fsType)
                logRepository?.logFSKit(
                    "mounted /Volumes/\(name) from \(url.path) (\(fsType))", category: "info")
            } catch {
                logRepository?.logFSKit(
                    "mount /Volumes/\(name) failed: \(error.localizedDescription)",
                    category: "error")
                let fail = NSAlert(error: error)
                fail.runModal()
            }
        }
    }

    /// Multi-partition flow. Show the user the partition list (with
    /// supported / skipped breakdown) and mount everything we can in
    /// one privileged shell invocation.
    private static func attachMultiPartition(url: URL,
                                             probe: DiskProbeResult,
                                             logRepository: LogRepository?) {
        // DiskJockey-shipped drivers: ext4 + NTFS via the FSKit
        // extensions. Apple-shipped drivers reachable via hdiutil:
        // FAT16/FAT32 (mount_msdos), exFAT (mount_exfat), HFS+
        // (mount_hfs), APFS (mount_apfs). Apple drivers ONLY work
        // when the source is raw — hdiutil doesn't understand
        // qcow2/vhd/vhdx/vmdk so partitions inside containers route
        // only to our extensions.
        let ourKinds: Set<String> = ["ext4", "ext3", "ext2", "ntfs"]
        let appleKinds: Set<String> = ["fat32", "fat16", "exfat", "hfs_plus", "apfs"]
        let containerSupportsApple = ["raw", "vhd", "vmdk"].contains(probe.container)
        func isSupported(_ p: DiskProbeResult.Partition) -> Bool {
            if ourKinds.contains(p.fsKind) { return true }
            if appleKinds.contains(p.fsKind) && containerSupportsApple { return true }
            return false
        }
        let supported = probe.partitions.filter(isSupported)
        let skipped = probe.partitions.filter { !isSupported($0) }

        if supported.isEmpty {
            let alert = NSAlert()
            alert.messageText = "No mountable partitions"
            var msg = "\(url.lastPathComponent) has \(probe.partitions.count) partition(s) (\(probe.table.uppercased())) but none can be mounted."
            if !containerSupportsApple {
                let appleInside = probe.partitions.filter { appleKinds.contains($0.fsKind) }
                if !appleInside.isEmpty {
                    msg += " \(appleInside.count) FAT32/exFAT/HFS+/APFS partition(s) require a raw, VHD, or VMDK source. Convert with a disk-image converter tool (e.g. `qemu-img convert -O raw`)."
                }
            }
            alert.informativeText = msg
            alert.runModal()
            return
        }

        let lines = probe.partitions.map { p -> String in
            let support = isSupported(p) ? "✓" : "—"
            let label = p.label.flatMap { $0.isEmpty ? nil : " \"\($0)\"" } ?? ""
            let mb = String(format: "%.1f", Double(p.length) / (1024 * 1024))
            let driver: String
            if ourKinds.contains(p.fsKind) { driver = " — DiskJockey driver" }
            else if appleKinds.contains(p.fsKind) && containerSupportsApple { driver = " — Apple driver via hdiutil" }
            else if appleKinds.contains(p.fsKind) { driver = " — needs raw/VHD/VMDK source" }
            else { driver = " — no driver" }
            return "  \(support) p\(p.index): \(p.fsKind)\(label), \(mb) MiB\(driver)"
        }.joined(separator: "\n")

        let prefix = url.deletingPathExtension().lastPathComponent
        let alert = NSAlert()
        alert.messageText = "\(probe.partitions.count) partition\(probe.partitions.count == 1 ? "" : "s") detected (\(probe.table.uppercased()))"
        var info = "\(url.lastPathComponent) (\(probe.container)):\n\(lines)\n\nWill mount \(supported.count) partition\(supported.count == 1 ? "" : "s"). Each volume will appear under its own label in /Volumes."
        if !skipped.isEmpty {
            info += "\n\(skipped.count) partition\(skipped.count == 1 ? "" : "s") skipped."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Mount All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        logRepository?.logFSKit(
            "attach-all-partitions \(probe.container) \(supported.count)p: \(url.path)",
            category: "info")
        Task { @MainActor in
            do {
                let mounted = try await FSKitMountService.shared.attachAllPartitions(
                    imagePath: url.path,
                    imageURL: url,
                    mountPointPrefix: prefix,
                    partitions: probe.partitions,
                    container: probe.container)
                logRepository?.logFSKit(
                    "mounted \(mounted.count) partition(s): \(mounted.joined(separator: ", "))",
                    category: "info")
            } catch {
                logRepository?.logFSKit(
                    "attach-all-partitions failed: \(error.localizedDescription)",
                    category: "error")
                let fail = NSAlert(error: error)
                fail.runModal()
            }
        }
    }

    /// Open a file picker then route through `attachUserPickedImage`.
    /// Sidebar "Add Disk Image" button entry point.
    static func promptAndAttachAuto(logRepository: LogRepository? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Choose a disk image"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Pick a disk image to mount. Filesystem will be detected automatically."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            var probe: DiskProbeResult? = SwiftPartitionProbe.probe(at: url)
            if probe == nil {
                probe = try? await DJAgentClient.shared.probeImage(atPath: url.path)
            }
            if let p = probe, p.table != "none", !p.partitions.isEmpty {
                attachMultiPartition(url: url, probe: p, logRepository: logRepository)
                return
            }
            attachUserPickedImage(at: url, logRepository: logRepository)
        }
    }

    static func promptAndAttach(fsType: String, logRepository: LogRepository? = nil) {
        let display = fsType.uppercased()
        let panel = NSOpenPanel()
        panel.title = "Choose a \(display) image or device"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Pick a .img or block device to mount as \(fsType)."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // DA mounts at the volume's own label — no need to ask the user for a name.
        let name = url.deletingPathExtension().lastPathComponent
        logRepository?.logFSKit(
            "attach (\(fsType)) requested: \(url.path)", category: "info")
        Task { @MainActor in
            do {
                try await FSKitMountService.shared.attach(
                    imagePath: url.path, name: name, fsType: fsType)
                logRepository?.logFSKit(
                    "mounted \(url.path) (\(fsType))", category: "info")
            } catch {
                logRepository?.logFSKit(
                    "mount /Volumes/\(name) failed: \(error.localizedDescription)",
                    category: "error")
                let fail = NSAlert(error: error)
                fail.runModal()
            }
        }
    }
}

// MARK: - LogRepository convenience

extension LogRepository {
    /// Append a user-visible log entry tagged with the FSKit source.
    /// The Logs panel filters on `category`, so we keep "error" / "info" etc
    /// for classification and stuff the subsystem context into `source`.
    fileprivate func logFSKit(_ message: String, category: String) {
        addLogEntry(LogEntry(
            message: message,
            category: category,
            source: "FSKit"
        ))
    }
}
