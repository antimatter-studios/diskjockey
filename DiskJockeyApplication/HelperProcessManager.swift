// HelperProcessManager.swift
// DiskJockeyApplication
//
// Manages the lifecycle of the DiskJockeyHelper and diskjockey-backend processes.
// Ensures they are running, restarts them if needed, and shuts them down gracefully.

import Foundation
import AppKit
import DiskJockeyHelperLibrary
import ServiceManagement

class HelperProcessManager {
    private var helperProcess: Process?
    private var backendProcess: Process?
    private let helperBundleID = "com.antimatter-studios.diskjockeyhelper"
    private let helperAppName = "DiskJockeyHelper.app"
    private let backendExecutableName = "diskjockey-backend"
    private let shutdownTimeout: TimeInterval = 10
    private var isShuttingDown = false

    // Launch and monitor the helper app
    func launchAndMonitorHelper(completion: @escaping (Int?) -> Void) {
        guard !isShuttingDown else { return }
        if isHelperRunning() { return }
        let helperIdentifier = "com.antimatter-studios.diskjockeyhelper"

        // Listen for the port notification from the helper
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("DiskJockeyHelperPort"),
            object: nil,
            queue: .main
        ) { notification in
            if let userInfo = notification.userInfo,
               let port = userInfo["port"] as? Int {
                NSLog("Received helper port via distributed notification: \(port)")
                completion(port)
            } else if let userInfo = notification.userInfo,
                      let portStr = userInfo["port"] as? String,
                      let port = Int(portStr) {
                // Defensive: handle string payload
                NSLog("Received helper port (string) via distributed notification: \(port)")
                completion(port)
            }
        }

        // Launch the helper via SMAppService
        let loginItem = SMAppService.loginItem(identifier: helperIdentifier)
        do {
            try loginItem.register()
            NSLog("Requested launch of helper via SMAppService")
            // The helper will post a notification with the port when ready
        } catch {
            NSLog("Failed to register helper with SMAppService: \(error)")
            completion(nil)
        }
    }

    /// Launch and monitor the backend, capturing its stdout to extract the LISTEN_PORT, then call completion with the port.
    func launchAndMonitorBackend(helperPort: Int, completion: @escaping (Int?) -> Void) {
        guard !isShuttingDown else { completion(nil); return }
        if isBackendRunning() { completion(nil); return }
        guard let backendURL = findBackendExecutableURL() else { completion(nil); return }
        
        let backendDir = ensureDiskJockeyAppSupportDirectory()
        
        let process = Process()
        process.executableURL = backendURL
        process.arguments = [
            "--config-dir", backendDir.path, 
            "--helper-port", String(helperPort)
        ]
        
        process.terminationHandler = { [weak self] proc in
            guard let self = self, !self.isShuttingDown else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.launchAndMonitorBackend(helperPort: helperPort, completion: completion)
            }
        }

        do {
            try process.run()
            backendProcess = process
            NSLog("Launched diskjockey-backend with config at \(backendDir.path)")
            // Backend does not output any port; call completion immediately
            completion(helperPort)
        } catch {
            NSLog("Failed to launch diskjockey-backend: \(error)")
            completion(nil)
        }
    }

    // Graceful shutdown of both processes using HelperAPI
    func shutdownChildrenGracefully(helperAPI: HelperAPI, completion: @escaping () -> Void) {
        isShuttingDown = true
        let group = DispatchGroup()
        if isHelperRunning() {
            group.enter()
            helperAPI.shutdown { result in
                self.waitForProcessExit(self.helperProcess, timeout: self.shutdownTimeout) {
                    group.leave()
                }
            }
        }
        // Backend will be shut down by the helper in response to shutdown command
        // Still wait for backend process exit for robustness
        if isBackendRunning() {
            group.enter()
            self.waitForProcessExit(self.backendProcess, timeout: self.shutdownTimeout) {
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion()
        }
    }

    private func isHelperRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: helperBundleID).isEmpty
    }

    private func isBackendRunning() -> Bool {
        // You may want to check by PID or socket availability
        // For now, just check if process is non-nil and running
        return backendProcess?.isRunning ?? false
    }

    private func findHelperAppURL() -> URL? {
        // Assume helper is embedded in main app bundle
        let mainBundle = Bundle.main.bundleURL
        let loginItemsURL = mainBundle.appendingPathComponent("Contents/Library/LoginItems/")
        let helperURL = loginItemsURL.appendingPathComponent(helperAppName)
        return FileManager.default.fileExists(atPath: helperURL.path) ? helperURL : nil
    }

    private func findBackendExecutableURL() -> URL? {
        // Assume backend is bundled in Resources or a known path
        let mainBundle = Bundle.main.bundleURL
        let backendURL = mainBundle.appendingPathComponent("Contents/Resources/").appendingPathComponent(backendExecutableName)
        return FileManager.default.fileExists(atPath: backendURL.path) ? backendURL : nil
    }

    private func waitForProcessExit(_ process: Process?, timeout: TimeInterval, completion: @escaping () -> Void) {
        guard let process = process else { completion(); return }
        let start = Date()
        func check() {
            if !process.isRunning || Date().timeIntervalSince(start) > timeout {
                completion()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: check)
            }
        }
        check()
    }

    /// Ensures the Application Support/DiskJockey directory exists and returns its URL
    func ensureDiskJockeyAppSupportDirectory() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let resourcesDir = appSupport.appendingPathComponent("DiskJockey")
        try? fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        return resourcesDir
    }
}
