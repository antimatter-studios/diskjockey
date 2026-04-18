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
        try await Self.runAsAdmin(
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
    /// Eventual replacement: an SMAppService privileged helper (see
    /// FB follow-up).
    ///
    /// `arguments` are quoted defensively. The caller is expected to pass
    /// absolute paths only — `validateMountName` already rules out the
    /// most dangerous shell metacharacters in the mount-name portion.
    private static func runAsAdmin(executable: String, arguments: [String]) async throws {
        // Build the shell command. Each argument is single-quoted with any
        // embedded single-quotes escaped — the standard
        // `'\''`-terminate-reopen pattern — so shell interpretation of the
        // user-provided source path / mount name cannot inject flags or
        // metacharacters. osascript receives that string inside a double-
        // quoted AppleScript literal; its interpretation rules are also
        // handled by escaping `\` and `"`.
        let shellArgs = ([executable] + arguments).map { Self.shellQuote($0) }
            .joined(separator: " ")
        let appleScript = "do shell script \(Self.appleScriptQuote(shellArgs)) " +
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

    private static func shellQuote(_ s: String) -> String {
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
    static func promptAndDetach() {
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
        Task { @MainActor in
            do {
                try await FSKitMountService.shared.detach(name: name)
                let ok = NSAlert()
                ok.messageText = "Detached /Volumes/\(name)"
                ok.runModal()
            } catch {
                let fail = NSAlert(error: error)
                fail.runModal()
            }
        }
    }

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
