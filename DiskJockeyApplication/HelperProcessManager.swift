// HelperProcessManager.swift
// DiskJockeyApplication
//
// Manages the lifecycle of the DiskJockeyHelper and diskjockey-backend processes.
// Ensures they are running, restarts them if needed, and shuts them down gracefully.

import Foundation
import AppKit

class HelperProcessManager {
    private var helperProcess: Process?
    private var backendProcess: Process?
    private let helperBundleID = "com.antimatter-studios.diskjockeyhelper"
    private let helperAppName = "DiskJockeyHelper.app"
    private let backendExecutableName = "diskjockey-backend"
    private let shutdownTimeout: TimeInterval = 10
    private var isShuttingDown = false

    // Launch and monitor the helper app
    func launchAndMonitorHelper() {
        guard !isShuttingDown else { return }
        if isHelperRunning() { return }
        guard let helperURL = findHelperAppURL() else { return }
        let process = Process()
        process.executableURL = helperURL.appendingPathComponent("Contents/MacOS/DiskJockeyHelper")
        process.terminationHandler = { [weak self] proc in
            guard let self = self, !self.isShuttingDown else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.launchAndMonitorHelper()
            }
        }
        do {
            try process.run()
            helperProcess = process
            NSLog("Launched DiskJockeyHelper")
        } catch {
            NSLog("Failed to launch DiskJockeyHelper: \(error)")
        }
    }

    // Launch and monitor the remote disk manager
    func launchAndMonitorBackend() {
        guard !isShuttingDown else { return }
        if isBackendRunning() { return }
        guard let backendURL = findBackendExecutableURL() else { return }
        let process = Process()
        process.executableURL = backendURL
        process.terminationHandler = { [weak self] proc in
            guard let self = self, !self.isShuttingDown else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.launchAndMonitorBackend()
            }
        }
        do {
            try process.run()
            backendProcess = process
            NSLog("Launched diskjockey-backend")
        } catch {
            NSLog("Failed to launch diskjockey-backend: \(error)")
        }
    }

    // Graceful shutdown of both processes
    func shutdownChildrenGracefully(completion: @escaping () -> Void) {
        isShuttingDown = true
        let group = DispatchGroup()
        if isHelperRunning() {
            group.enter()
            sendShutdownIPC(socketPath: "/tmp/diskjockey.helper.sock") {
                self.waitForProcessExit(self.helperProcess, timeout: self.shutdownTimeout) {
                    group.leave()
                }
            }
        }
        if isBackendRunning() {
            group.enter()
            sendShutdownIPC(socketPath: "/tmp/diskjockey.backend.sock") {
                self.waitForProcessExit(self.backendProcess, timeout: self.shutdownTimeout) {
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            completion()
        }
    }

    // MARK: - Helpers

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
    private func sendShutdownIPC(socketPath: String, completion: @escaping () -> Void) {
        // Send a shutdown request to the given UNIX domain socket
        DispatchQueue.global().async {
            if let fd = socket(AF_UNIX, SOCK_STREAM, 0) as Int32?, fd >= 0 {
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                    let pathData = socketPath.utf8CString
                    buf.copyBytes(from: pathData)
                }
                let len = socklen_t(MemoryLayout<sa_family_t>.size + socketPath.utf8CString.count)
                let result = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, len)
                    }
                }
                if result == 0 {
                    // Send a shutdown command (define your protocol, e.g., type 99)
                    var shutdownType: UInt8 = 99
                    _ = withUnsafeBytes(of: &shutdownType) { write(fd, $0.baseAddress, 1) }
                }
                close(fd)
            }
            DispatchQueue.main.async { completion() }
        }
    }
}
