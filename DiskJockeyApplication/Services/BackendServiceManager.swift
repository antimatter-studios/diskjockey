import Foundation
import ServiceManagement
import Combine
import DiskJockeyLibrary

/// Manages the Go backend as a LaunchAgent via SMAppService.
/// The backend runs independently of the desktop app.
@MainActor
public final class BackendServiceManager: ObservableObject {
    private let appGroupID = "group.com.antimatterstudios.diskjockey"
    private let backendPlistName = "com.antimatterstudios.diskjockey.backend"
    private let xpcBridgePlistName = "com.antimatterstudios.diskjockey.xpc-bridge"
    private let logger: LogRepository?

    @Published public private(set) var port: Int?
    @Published public private(set) var isRegistered: Bool = false

    public init(logger: LogRepository? = nil) {
        self.logger = logger
    }

    private func log(_ msg: String) {
        NSLog("[BackendServiceManager] %@", msg)
        logger?.addLogEntry(LogEntry(message: msg, category: "service"))
    }

    // MARK: - LaunchAgent Registration

    /// Register both the backend and XPC bridge as LaunchAgents.
    public func register() {
        if #available(macOS 13.0, *) {
            registerAgent(plistName: backendPlistName, description: "backend")
            registerAgent(plistName: xpcBridgePlistName, description: "XPC bridge")
        } else {
            log("SMAppService requires macOS 13+")
        }
    }

    @available(macOS 13.0, *)
    private func registerAgent(plistName: String, description: String) {
        let service = SMAppService.agent(plistName: "\(plistName).plist")
        do {
            try service.register()
            log("\(description) LaunchAgent registered successfully")
        } catch {
            log("Failed to register \(description) LaunchAgent: \(error)")
            let status = service.status
            log("\(description) service status: \(status)")
        }
        if service.status == .enabled {
            isRegistered = true
        }
    }

    /// Unregister both LaunchAgents.
    public func unregister() {
        if #available(macOS 13.0, *) {
            unregisterAgent(plistName: backendPlistName, description: "backend")
            unregisterAgent(plistName: xpcBridgePlistName, description: "XPC bridge")
            isRegistered = false
            port = nil
        }
    }

    @available(macOS 13.0, *)
    private func unregisterAgent(plistName: String, description: String) {
        let service = SMAppService.agent(plistName: "\(plistName).plist")
        do {
            try service.unregister()
            log("\(description) LaunchAgent unregistered")
        } catch {
            log("Failed to unregister \(description) LaunchAgent: \(error)")
        }
    }

    // MARK: - Port Discovery

    /// Read the backend port from the shared app group container.
    /// The backend writes this file on startup.
    public func discoverPort(retries: Int = 20, interval: TimeInterval = 0.5) async -> Int? {
        for attempt in 1...retries {
            if let port = readPortFile() {
                self.port = port
                log("Discovered backend port: \(port) (attempt \(attempt))")
                return port
            }

            // Also check UserDefaults
            if let defaults = UserDefaults(suiteName: appGroupID) {
                let p = defaults.integer(forKey: "backend_port")
                if p > 0 {
                    self.port = p
                    log("Discovered backend port from UserDefaults: \(p)")
                    return p
                }
            }

            if attempt < retries {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }

        log("Failed to discover backend port after \(retries) attempts")
        return nil
    }

    private func readPortFile() -> Int? {
        // Try app group container first
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            let portFileURL = containerURL.appendingPathComponent("backend.port")
            NSLog("[BackendServiceManager] Trying port file at: %@", portFileURL.path)
            if let contents = try? String(contentsOf: portFileURL, encoding: .utf8),
               let port = Int(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
                NSLog("[BackendServiceManager] Read port from app group: %d", port)
                return port
            }
        }

        // Try the direct filesystem path (for when backend runs outside sandbox)
        let directPath = NSHomeDirectory()
            .appending("/Library/Group Containers/\(appGroupID)/backend.port")
        NSLog("[BackendServiceManager] Trying direct path: %@", directPath)
        if let contents = try? String(contentsOfFile: directPath, encoding: .utf8),
           let port = Int(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
            NSLog("[BackendServiceManager] Read port from direct path: %d", port)
            return port
        }

        // Try Application Support (old config location)
        let appSupportPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DiskJockey/backend.port")
        if let path = appSupportPath {
            NSLog("[BackendServiceManager] Trying app support: %@", path.path)
            if let contents = try? String(contentsOf: path, encoding: .utf8),
               let port = Int(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
                NSLog("[BackendServiceManager] Read port from app support: %d", port)
                return port
            }
        }

        NSLog("[BackendServiceManager] No port file found")
        return nil
    }

    /// Check if the backend is currently reachable by reading the port file.
    public var isBackendAvailable: Bool {
        return readPortFile() != nil
    }
}
