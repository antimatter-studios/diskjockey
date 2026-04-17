import Foundation
import AppKit
import OSLog

/// Mounts ext4 images / block devices via macOS 26's `mount -F` path, which
/// routes to fskitd without the `com.apple.developer.fskit.fsclient`
/// entitlement. Companion to `MountManager` (File Provider) — FSKit
/// extensions live in their own lane because they bypass NSFileProvider
/// entirely.
///
/// The bundled DiskJockeyEXT4 FSKit extension must be registered with
/// pluginkit (which happens automatically once the host app has launched
/// at least once with the embedded .appex in place).
@MainActor
final class FSKitMountService {
    static let shared = FSKitMountService()

    private let logger = Logger(subsystem: "com.antimatterstudios.diskjockey", category: "FSKitMount")

    enum FSKitError: LocalizedError {
        case processFailed(exitCode: Int32, stderr: String)
        case mountPointInUse(String)
        case invalidMountName(String)

        var errorDescription: String? {
            switch self {
            case .processFailed(let code, let stderr):
                return "mount exited \(code): \(stderr)"
            case .mountPointInUse(let path):
                return "mount point \(path) already has a volume attached"
            case .invalidMountName(let name):
                return "invalid mount name \"\(name)\": must be non-empty and contain no slashes"
            }
        }
    }

    // MARK: - Attach

    /// Mount an ext4 image or block device at `/Volumes/<name>`.
    /// - Parameters:
    ///   - source: absolute path to an ext4 .img or /dev/diskN node.
    ///   - name: volume name — becomes the mount point under /Volumes.
    func attach(imagePath source: String, name: String) async throws {
        try Self.validateMountName(name)
        let mountPoint = "/Volumes/\(name)"

        if FileManager.default.fileExists(atPath: mountPoint) {
            // Allow reuse only if the directory is empty (not already a mount).
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint)) ?? []
            if !contents.isEmpty {
                throw FSKitError.mountPointInUse(mountPoint)
            }
        } else {
            try FileManager.default.createDirectory(
                atPath: mountPoint, withIntermediateDirectories: true, attributes: nil
            )
        }

        logger.info("attach \(source, privacy: .public) -> \(mountPoint, privacy: .public)")
        try await Self.run(
            executable: "/sbin/mount",
            arguments: ["-F", "-t", "ext4", source, mountPoint]
        )
    }

    // MARK: - Detach

    /// Unmount a volume previously attached via `attach(imagePath:name:)`.
    func detach(name: String) async throws {
        try Self.validateMountName(name)
        let mountPoint = "/Volumes/\(name)"
        logger.info("detach \(mountPoint, privacy: .public)")
        try await Self.run(
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
                    let msg = String(data: data ?? Data(), encoding: .utf8) ?? ""
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
    static func promptAndAttach() {
        let panel = NSOpenPanel()
        panel.title = "Choose an ext4 image or device"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Pick a .img or block device to mount as ext4."
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
        Task { @MainActor in
            do {
                try await FSKitMountService.shared.attach(imagePath: url.path, name: name)
                let ok = NSAlert()
                ok.messageText = "Mounted at /Volumes/\(name)"
                ok.runModal()
            } catch {
                let fail = NSAlert(error: error)
                fail.runModal()
            }
        }
    }
}
