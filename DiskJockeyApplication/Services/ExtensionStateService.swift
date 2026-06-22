//
// ExtensionStateService.swift — reads (never writes) the enable/disable
// state of our FSKit filesystem extensions via the PUBLIC FSKit management
// API (`FSClient`). In-app, sandbox-safe, and MAS-legal — no helper
// process, no `pluginkit`. macOS 15.4+.
//
// `FSClient.shared.installedExtensions` returns `[FSModuleIdentity]`, each
// carrying a `bundleIdentifier` and an `isEnabled` flag — exactly the
// toggle the user sets in System Settings → General → Login Items → File
// System Extensions. We can't *change* it (only the user can), but we can
// read it directly. The earlier sandboxed-`pluginkit` and unsandboxed-agent
// approaches were dead ends (pkd is sandbox-blocked; an unsandboxed helper
// can't ship through MAS); `FSClient` is the sanctioned path.
//
// FSClient only knows FSKit modules, so the File Provider extension (not an
// FSKit module) has no entry; its key is left absent and the UI falls back
// to functional evidence (a configured mount implies it's on).
//

import Foundation
import Combine
import AppKit
import FSKit
import OSLog

@MainActor
public final class ExtensionStateService: ObservableObject {

    private static let log = Logger(subsystem: "com.antimatterstudios.diskjockey", category: "ExtensionState")
    /// Short fs key ("ext4", "ntfs", "erofs", "squashfs") → whether its
    /// FSKit extension is enabled. A key is ABSENT when it couldn't be
    /// determined (treat as unknown; the UI falls back to mounted-volume
    /// evidence).
    @Published public private(set) var enabled: [String: Bool] = [:]

    private static let bundlePrefix = "com.antimatterstudios.diskjockey"
    private static let keys = ["ext4", "ntfs", "erofs", "squashfs", "fileprovider"]

    /// Re-poll cadence while the app is open, so a toggle flipped in System
    /// Settings shows up without the user re-navigating.
    private static let pollInterval: TimeInterval = 60

    private var activationObserver: NSObjectProtocol?
    private var pollTimer: Timer?

    public init() {
        refresh()
        // Re-read when the user returns to the app — typically right after
        // toggling an extension in System Settings.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Steady background poll: enablement can change while the app is
        // already frontmost (toggled in a separate System Settings window).
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pollInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        pollTimer?.invalidate()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    /// Look up a single key. nil = couldn't determine.
    public func isEnabled(_ key: String) -> Bool? { enabled[key] }

    /// Ask FSKit for the installed modules + their enabled flag. On failure
    /// (pre-15.4, missing entitlement, transient) we keep the last-known
    /// state rather than flicker; the UI falls back to mounted-volume
    /// evidence for keys we have no state for.
    public func refresh() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let modules = try await FSClient.shared.installedExtensions
                var fresh: [String: Bool] = [:]
                for key in Self.keys {
                    let bundleID = "\(Self.bundlePrefix).\(key)"
                    if let module = modules.first(where: { $0.bundleIdentifier == bundleID }) {
                        fresh[key] = module.isEnabled
                    }
                }
                self.apply(fresh)
            } catch {
                Self.log.error("FSClient.installedExtensions failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func apply(_ fresh: [String: Bool]) {
        guard fresh != enabled else { return }
        enabled = fresh
        Self.log.info("extension enable-state: \(fresh.map { "\($0)=\($1 ? "on" : "off")" }.sorted().joined(separator: ", "), privacy: .public)")
    }
}
