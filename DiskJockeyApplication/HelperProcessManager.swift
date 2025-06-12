// HelperProcessManager.swift
// DiskJockeyApplication

import Foundation
import DiskJockeyHelperLibrary
import AppKit
import os.log
import ServiceManagement

class HelperProcessManager {
    private var helperProcess: Process?
    private let helperAppName = "DiskJockeyHelper.app"
    private let backendExecutableName = "diskjockey-backend"
    private let shutdownTimeout: TimeInterval = 10
    private var isShuttingDown = false

    func launchAndMonitorHelper(completion: @escaping (Int?) -> Void) {
        guard !isShuttingDown else { return }
        
        self.listenForHelperReadyNotification()

        guard let helperURL = findHelperAppURL() else {
            NSLog("Failed to find helper app URL")
            completion(nil)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { (app, error) in
            if let error = error {
                NSLog("Failed to launch helper app: \(error)")
            } else {
                NSLog("Requested launch of helper app")
            }
        }
    }

    func launchAndMonitorBackend(helperPort: Int, completion: @escaping (Int?) -> Void) {
        guard !isShuttingDown else { completion(nil); return }
        guard let backendURL = findBackendExecutableURL() else { completion(nil); return }

        let backendDir = ensureDiskJockeyAppSupportDirectory()

        let process = Process()
        process.executableURL = backendURL
        process.arguments = [
            "--config-dir", backendDir.path,
            "--helper-port", String(helperPort)
        ]

        process.terminationHandler = { [weak self] _ in
            guard let self = self, !self.isShuttingDown else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.launchAndMonitorBackend(helperPort: helperPort, completion: completion)
            }
        }

        do {
            try process.run()
            NSLog("Launched backend with helper port \(helperPort)")
            completion(helperPort)
        } catch {
            NSLog("Failed to launch backend: \(error)")
            completion(nil)
        }
    }

    private func findHelperAppURL() -> URL? {
        let loginItemsURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/")
        let helperURL = loginItemsURL.appendingPathComponent(helperAppName)
        return FileManager.default.fileExists(atPath: helperURL.path) ? helperURL : nil
    }

    private func findBackendExecutableURL() -> URL? {
        let backendURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/").appendingPathComponent(backendExecutableName)
        return FileManager.default.fileExists(atPath: backendURL.path) ? backendURL : nil
    }

    func ensureDiskJockeyAppSupportDirectory() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let resourcesDir = appSupport.appendingPathComponent("DiskJockey")
        try? fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        return resourcesDir
    }

    func listenForHelperReadyNotification() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.antimatter-studios.diskjockeyhelper.ready"),
            object: nil,
            queue: .main
        ) { notification in
            NSLog("Received helper ready notification")
            // You can extract userInfo here if needed, e.g. the port number
            if let userInfo = notification.userInfo, let port = userInfo["port"] as? Int {
                NSLog("Helper is ready on port \(port)")
                // You can trigger any logic here as needed
            }
        }
    }
}
