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
    func attach(imagePath source: String, name: String, fsType: String) async throws {
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
        let shellCmd = "/bin/mkdir -p \(Self.shellQuote(mountPoint)) && "
            + "/sbin/mount -F -t \(Self.shellQuote(fsType)) "
            + "\(Self.shellQuote(source)) \(Self.shellQuote(mountPoint))"
        try await Self.runShellAsAdmin(command: shellCmd)
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
