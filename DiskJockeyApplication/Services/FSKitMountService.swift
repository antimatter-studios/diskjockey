import Foundation
import AppKit
import OSLog
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
        let mountPoint = "/Volumes/\(name)"

        // /Volumes/ is root-owned; a sandboxed app can't `mkdir` there
        // and the FileManager.createDirectory call would fail before we
        // even reached the privileged escalation. Defer the mount-point
        // creation into the admin shell command so it runs with the
        // privileges that already need to exist for `mount -F` itself.
        // Pre-flight existence check via stat is allowed inside the
        // sandbox (it's a read), so we still surface a clean error if
        // the mount point is already a live mount.
        if FileManager.default.fileExists(atPath: mountPoint) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint)) ?? []
            if !contents.isEmpty {
                throw FSKitError.mountPointInUse(mountPoint)
            }
        }

        logger.info("attach \(fsType, privacy: .public) \(source, privacy: .public) -> \(mountPoint, privacy: .public)")
        // `mkdir -p` is idempotent on an existing empty directory, so
        // running it unconditionally is safe and removes the
        // sandbox-vs-privileged split.
        var shellCmd = "/bin/mkdir -p \(Self.shellQuote(mountPoint)) && "
            + "/sbin/mount -F -t \(Self.shellQuote(fsType)) "
        if let opts = mountOptions, !opts.isEmpty {
            shellCmd += "-o \(Self.shellQuote(opts)) "
        }
        shellCmd += "\(Self.shellQuote(source)) \(Self.shellQuote(mountPoint))"
        try await Self.runShellAsAdmin(command: shellCmd)
    }

    /// Multi-partition attach: probe the image's partition table, then
    /// mount every partition we have a driver for in a single privileged
    /// shell invocation. Partitions whose FS we don't ship (FAT32 /
    /// exFAT / HFS+ / APFS / linux_swap / iso9660 / squashfs) are skipped
    /// with a log line — the caller decides whether to surface that to
    /// the user.
    ///
    /// `mountPointPrefix` is the base name; partitions land at
    /// `/Volumes/<prefix>-pN`. Returns the list of mount points actually
    /// attached.
    func attachAllPartitions(imagePath source: String,
                             mountPointPrefix: String,
                             partitions: [DiskProbeResult.Partition],
                             container: String = "raw") async throws -> [String] {
        try Self.validateMountName(mountPointPrefix)

        // Classify partitions by which driver mounts them.
        //
        //   - ext4/ext3/ext2/NTFS  -> our DiskJockey extensions (callback
        //     + slice path; works with raw OR container source).
        //   - FAT16/FAT32          -> Apple's mount_msdos.
        //   - exFAT                -> Apple's mount_exfat.
        //   - HFS+                 -> Apple's mount_hfs.
        //   - APFS                 -> Apple's mount_apfs.
        //
        // Apple's drivers want a real /dev/diskN node, which we synthesize
        // by `hdiutil attach -nomount` of the source. hdiutil DOESN'T
        // understand qcow2/vhd/vhdx/vmdk — so when the source is a
        // container with Apple-driver partitions we skip those with a
        // log message and tell the user to convert to raw if they want
        // them mounted.
        struct Classified {
            var ourPartitions: [(part: DiskProbeResult.Partition, fs: String)] = []
            var applePartitions: [(part: DiskProbeResult.Partition, fs: String)] = []
            var skipped: [DiskProbeResult.Partition] = []
        }
        var c = Classified()
        for part in partitions {
            switch part.fsKind {
            case "ext4", "ext3", "ext2": c.ourPartitions.append((part, "ext4"))
            case "ntfs":                  c.ourPartitions.append((part, "ntfs"))
            case "fat32", "fat16":
                if container == "raw" { c.applePartitions.append((part, "msdos")) }
                else { c.skipped.append(part) }
            case "exfat":
                if container == "raw" { c.applePartitions.append((part, "exfat")) }
                else { c.skipped.append(part) }
            case "hfs_plus":
                if container == "raw" { c.applePartitions.append((part, "hfs")) }
                else { c.skipped.append(part) }
            case "apfs":
                if container == "raw" { c.applePartitions.append((part, "apfs")) }
                else { c.skipped.append(part) }
            default:                     c.skipped.append(part)
            }
        }
        for s in c.skipped {
            logger.info("skip partition \(s.index) (\(s.fsKind, privacy: .public)): no driver path (container=\(container, privacy: .public))")
        }

        // Apple-driver partitions need an hdiutil-attached parent.
        var hdiutilSlices: [Int: String] = [:]   // partition index -> /dev/diskNsM
        var hdiutilParent: String?
        if !c.applePartitions.isEmpty {
            let result = try Self.runHdiutilAttach(at: source)
            hdiutilParent = result.parentDevice
            // hdiutil returns slices in arbitrary order; we map them by
            // their numeric suffix back to the partition index. MBR + GPT
            // primary partitions follow the convention "diskNs(index+1)".
            for slice in result.slices {
                if let idx = Self.sliceNumber(of: slice) {
                    hdiutilSlices[idx - 1] = slice
                }
            }
            logger.info("hdiutil attach \(source, privacy: .public) -> \(result.parentDevice, privacy: .public) (\(result.slices.count, privacy: .public) slices)")
        }

        // Build the privileged shell command — every supported partition
        // mounts in one sudo prompt.
        var pieces: [String] = []
        var mounts: [String] = []
        for (part, fs) in c.ourPartitions {
            let name = "\(mountPointPrefix)-p\(part.index)"
            try Self.validateMountName(name)
            let mountPoint = "/Volumes/\(name)"
            mounts.append(mountPoint)
            pieces.append("/bin/mkdir -p \(Self.shellQuote(mountPoint))")
            pieces.append(
                "/sbin/mount -F -t \(Self.shellQuote(fs)) "
                + "-o \(Self.shellQuote("partition_offset=\(part.start),partition_length=\(part.length)")) "
                + "\(Self.shellQuote(source)) \(Self.shellQuote(mountPoint))"
            )
        }
        for (part, fs) in c.applePartitions {
            guard let dev = hdiutilSlices[part.index] else {
                logger.error("apple partition \(part.index) (\(part.fsKind, privacy: .public)): no hdiutil slice mapped (parent=\(hdiutilParent ?? "?", privacy: .public))")
                continue
            }
            let name = "\(mountPointPrefix)-p\(part.index)"
            try Self.validateMountName(name)
            let mountPoint = "/Volumes/\(name)"
            mounts.append(mountPoint)
            pieces.append("/bin/mkdir -p \(Self.shellQuote(mountPoint))")
            pieces.append("/sbin/mount -t \(Self.shellQuote(fs)) \(Self.shellQuote(dev)) \(Self.shellQuote(mountPoint))")
        }

        if mounts.isEmpty {
            // Nothing to mount — clean up the hdiutil attach if we made one.
            if let parent = hdiutilParent {
                _ = try? await Self.runHdiutilDetach(parent)
            }
            logger.info("attachAllPartitions \(source, privacy: .public): nothing supported (\(partitions.count) partitions seen, \(c.skipped.count) skipped)")
            return []
        }

        let shellCmd = pieces.joined(separator: " && ")
        logger.info("attachAllPartitions \(source, privacy: .public): mounting \(mounts.count, privacy: .public) partitions (\(c.ourPartitions.count) ours + \(c.applePartitions.count) apple) in one privileged batch")
        do {
            try await Self.runShellAsAdmin(command: shellCmd)
        } catch {
            // Mount failed mid-batch — make sure we don't leak the
            // hdiutil attach.
            if let parent = hdiutilParent {
                _ = try? await Self.runHdiutilDetach(parent)
            }
            throw error
        }
        return mounts
    }

    /// hdiutil-attach result. The parent is the whole-disk node, slices
    /// are individual partition nodes (each is mountable via Apple's
    /// driver).
    struct HdiutilAttachResult {
        let parentDevice: String       // e.g. "/dev/disk5"
        let slices: [String]           // e.g. ["/dev/disk5s1", "/dev/disk5s2"]
    }

    /// Run `hdiutil attach -nomount -plist <path>` and parse the output.
    /// Doesn't need admin — hdiutil sets up a dev node we can read but
    /// not mount without privilege. The actual `mount` call (admin) is
    /// chained into the same privileged shell as our extension mounts.
    static func runHdiutilAttach(at path: String) throws -> HdiutilAttachResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["attach", "-nomount", "-plist", path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            throw FSKitError.processFailed(exitCode: proc.terminationStatus, stderr: err)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try PropertyListSerialization.propertyList(
                from: outData, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw FSKitError.processFailed(exitCode: -1, stderr: "hdiutil plist parse failed")
        }
        // Whole-disk parent: dev-entry has no `s` suffix (or has
        // FDisk_partition_scheme / GUID_partition_scheme content-hint).
        // Slices: dev-entry contains "sN" suffix.
        var parent: String?
        var slices: [String] = []
        for entity in entities {
            guard let dev = entity["dev-entry"] as? String else { continue }
            // Parent: ends in "diskN" with no slice suffix.
            if dev.range(of: #"^/dev/disk\d+$"#, options: .regularExpression) != nil {
                parent = dev
            } else if dev.range(of: #"^/dev/disk\d+s\d+$"#, options: .regularExpression) != nil {
                slices.append(dev)
            }
        }
        guard let parent = parent else {
            throw FSKitError.processFailed(exitCode: -1, stderr: "hdiutil attached but no parent /dev/diskN found")
        }
        return HdiutilAttachResult(parentDevice: parent, slices: slices)
    }

    /// Detach a previously-attached hdiutil device. Best-effort — if the
    /// device has dependent mounts or is already gone we throw the
    /// hdiutil error so the caller can decide.
    static func runHdiutilDetach(_ device: String) async throws {
        try await Self.runAsAdmin(executable: "/usr/bin/hdiutil",
                                  arguments: ["detach", device])
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

    /// Unmount a volume previously attached via `attach(imagePath:name:)`.
    func detach(name: String) async throws {
        try Self.validateMountName(name)
        let mountPoint = "/Volumes/\(name)"
        logger.info("detach \(mountPoint, privacy: .public)")
        try await Self.runAsAdmin(
            executable: "/sbin/umount",
            arguments: [mountPoint]
        )
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

    /// Run a privileged command via `osascript "do shell script ... with
    /// administrator privileges"`. macOS presents the auth dialog; the
    /// user's admin credential is cached for the session so subsequent
    /// mounts within ~5 minutes skip the prompt.
    ///
    /// Chosen over NSAppleScript directly because osascript lives outside
    /// the host app sandbox and handles the privilege escalation cleanly.
    ///
    /// `arguments` are quoted defensively. The caller is expected to pass
    /// absolute paths only — `validateMountName` already rules out the
    /// most dangerous shell metacharacters in the mount-name portion.
    private static func runAsAdmin(executable: String, arguments: [String]) async throws {
        // Build the shell command. Each argument is single-quoted with any
        // embedded single-quotes escaped — the standard
        // `'\''`-terminate-reopen pattern — so shell interpretation of the
        // user-provided source path / mount name cannot inject flags or
        // metacharacters.
        let shellArgs = ([executable] + arguments).map { Self.shellQuote($0) }
            .joined(separator: " ")
        try await runShellAsAdmin(command: shellArgs)
    }

    /// Same admin escalation as `runAsAdmin`, but accepts a pre-built
    /// shell command string. Used by callers that need to chain
    /// multiple commands inside the SAME admin scope (e.g. `mkdir &&
    /// mount`, or `unmount && fsck_fskit`) so the user only sees
    /// one auth prompt.
    ///
    /// The caller is responsible for shell-quoting individual arguments
    /// in `command` (use `shellQuote`).
    static func runShellAsAdmin(command: String) async throws {
        let appleScript = "do shell script \(Self.appleScriptQuote(command)) " +
                          "with administrator privileges"

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]

            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = Pipe()

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                    return
                }
                let data = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                let msg = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Exit code 1 + "User canceled" is the cancelled-prompt signal.
                // Map that to a dedicated error so the UI can distinguish
                // "user cancelled" from "mount itself failed".
                if msg.contains("User canceled") || msg.contains("(-128)") {
                    continuation.resume(throwing: FSKitError.authorizationDenied(stderr: msg))
                } else if msg.contains("(-60005)")
                    || msg.localizedCaseInsensitiveContains("name or password was incorrect") {
                    // -60005 = "incorrect username or password" from
                    // SecurityFoundation. The osascript exits with
                    // rc=1 in this case, but the actionable problem
                    // for the user is "type your password again."
                    continuation.resume(throwing: FSKitError.authorizationDenied(
                        stderr: "Wrong password. Try again."))
                } else {
                    continuation.resume(
                        throwing: FSKitError.processFailed(
                            exitCode: proc.terminationStatus,
                            stderr: msg
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

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuote(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - User-facing menu helper

@MainActor
enum FSKitAttachController {
    /// Opens a file picker for an ext4 image then triggers `attach`.
    /// Meant to be called from a menu item; runs async, surfaces errors via
    /// `NSAlert`.
    /// Prompt the user to pick an active mount under /Volumes and unmount it.
    /// Uses the same privileged path as attach — osascript triggers the auth
    /// prompt, which is cached for ~5min after a successful attach.
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
        // Try multi-partition path first.
        if let probe = try? FSKitMountService.runDiskProbe(at: url.path),
           probe.table != "none",
           !probe.partitions.isEmpty {
            attachMultiPartition(url: url, probe: probe, logRepository: logRepository)
            return
        }

        // Single-FS fallback (original path).
        let detected = detectFSType(at: url)
        let fsType: String
        if let direct = detected.fsType {
            fsType = direct
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

        let fallbackName = url.deletingPathExtension().lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Mount as…"
        alert.informativeText = "Volume will appear at /Volumes/<name> (\(fsType.uppercased()))"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = fallbackName
        alert.accessoryView = input
        alert.addButton(withTitle: "Mount")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = input.stringValue.trimmingCharacters(in: .whitespaces)
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
        let containerSupportsApple = (probe.container == "raw")
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
                    msg += " \(appleInside.count) FAT32/exFAT/HFS+/APFS partition(s) need the source to be raw (hdiutil doesn't read \(probe.container)). Convert with `qemu-img convert -O raw`."
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
            else if appleKinds.contains(p.fsKind) { driver = " — needs raw source" }
            else { driver = " — no driver" }
            return "  \(support) p\(p.index): \(p.fsKind)\(label), \(mb) MiB\(driver)"
        }.joined(separator: "\n")

        let fallback = url.deletingPathExtension().lastPathComponent
        let alert = NSAlert()
        alert.messageText = "\(probe.partitions.count) partition\(probe.partitions.count == 1 ? "" : "s") detected (\(probe.table.uppercased()))"
        var info = "\(url.lastPathComponent) (\(probe.container)):\n\(lines)\n\nWill mount \(supported.count) partition\(supported.count == 1 ? "" : "s") at /Volumes/<name>-pN."
        if !skipped.isEmpty {
            info += "\n\(skipped.count) partition\(skipped.count == 1 ? "" : "s") skipped."
        }
        alert.informativeText = info
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = fallback
        alert.accessoryView = input
        alert.addButton(withTitle: "Mount All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let prefix = input.stringValue.trimmingCharacters(in: .whitespaces)
        logRepository?.logFSKit(
            "attach-all-partitions \(probe.container) \(supported.count)p: \(url.path) -> /Volumes/\(prefix)-pN",
            category: "info")
        Task { @MainActor in
            do {
                let mounted = try await FSKitMountService.shared.attachAllPartitions(
                    imagePath: url.path,
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
        attachUserPickedImage(at: url, logRepository: logRepository)
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

        let fallbackName = url.deletingPathExtension().lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Mount as…"
        alert.informativeText = "Volume will appear at /Volumes/<name>"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = fallbackName
        alert.accessoryView = input
        alert.addButton(withTitle: "Mount")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = input.stringValue.trimmingCharacters(in: .whitespaces)
        logRepository?.logFSKit(
            "attach (\(fsType)) requested: \(url.path) -> /Volumes/\(name)", category: "info")
        Task { @MainActor in
            do {
                try await FSKitMountService.shared.attach(
                    imagePath: url.path, name: name, fsType: fsType)
                logRepository?.logFSKit(
                    "mounted /Volumes/\(name) from \(url.path) (\(fsType))", category: "info")
                let ok = NSAlert()
                ok.messageText = "Mounted at /Volumes/\(name)"
                ok.runModal()
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
