import Foundation
import DiskJockeyLibrary

/// XPC Bridge Service entry point.
/// Runs as a LaunchAgent with a mach service name.
/// Manages the Go backend lifecycle and bridges fileprovider.proto requests
/// from the File Provider extension to backend.proto requests over TCP.

let machServiceName = "com.antimatterstudios.diskjockey.xpc-bridge"
let appGroupID = "group.com.antimatterstudios.diskjockey"

// MARK: - Start Go Backend

func startBackendIfNeeded() {
    let appGroupDir = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupID
    )

    guard let appGroupDir = appGroupDir else {
        NSLog("[DiskJockeyXPC] Cannot find app group container")
        return
    }

    let portFile = appGroupDir.appendingPathComponent("backend.port")
    let configDir = appGroupDir.appendingPathComponent("config")

    // Check if backend is already running by testing the port
    if let portStr = try? String(contentsOf: portFile, encoding: .utf8),
       let port = Int(portStr.trimmingCharacters(in: .whitespacesAndNewlines)),
       port > 0 {
        // Try connecting to verify it's alive
        if DiskJockeyXPC.sharedClient.connect() {
            NSLog("[DiskJockeyXPC] Backend already running on port %d", port)
            return
        }
        // Port file exists but backend is dead — clean up
        try? FileManager.default.removeItem(at: portFile)
    }

    // Find the backend binary relative to our XPC bundle
    // We're at DiskJockey.app/Contents/XPCServices/DiskJockeyXPC.xpc/Contents/MacOS/DiskJockeyXPC
    // Backend is at DiskJockey.app/Contents/MacOS/diskjockey-backend
    let xpcBundle = Bundle.main.bundlePath // .../DiskJockeyXPC.xpc
    let appContentsURL = URL(fileURLWithPath: xpcBundle)
        .deletingLastPathComponent() // .../XPCServices
        .deletingLastPathComponent() // .../Contents
    let backendURL = appContentsURL
        .appendingPathComponent("MacOS")
        .appendingPathComponent("diskjockey-backend")
    let resolvedPath = backendURL.path

    guard FileManager.default.fileExists(atPath: resolvedPath) else {
        NSLog("[DiskJockeyXPC] Backend binary not found at: %@", resolvedPath)
        return
    }

    // Create config dir if needed
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

    NSLog("[DiskJockeyXPC] Starting backend: %@", resolvedPath)
    NSLog("[DiskJockeyXPC] Config dir: %@", configDir.path)
    NSLog("[DiskJockeyXPC] Port file: %@", portFile.path)

    NSLog("[DiskJockeyXPC] Checking backend exists at: %@, exists: %d", resolvedPath, FileManager.default.fileExists(atPath: resolvedPath) ? 1 : 0)
    NSLog("[DiskJockeyXPC] Bundle.main.bundlePath: %@", Bundle.main.bundlePath)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
        "-c",
        "\"\(resolvedPath)\" --config-dir \"\(configDir.path)\" --port-file \"\(portFile.path)\" --no-timeout"
    ]

    do {
        try process.run()
        NSLog("[DiskJockeyXPC] Backend started with PID %d", process.processIdentifier)

        // Wait for port file to appear
        for _ in 1...20 {
            Thread.sleep(forTimeInterval: 0.5)
            if let portStr = try? String(contentsOf: portFile, encoding: .utf8),
               let port = Int(portStr.trimmingCharacters(in: .whitespacesAndNewlines)),
               port > 0 {
                NSLog("[DiskJockeyXPC] Backend listening on port %d", port)
                return
            }
        }
        NSLog("[DiskJockeyXPC] Backend started but port file not found after 10s")
    } catch {
        NSLog("[DiskJockeyXPC] Failed to start backend: %@", error.localizedDescription)
    }
}

// MARK: - XPC Listener Delegate

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        NSLog("[DiskJockeyXPC] Accepting new XPC connection")

        newConnection.exportedInterface = NSXPCInterface(with: FileProviderXPCProtocol.self)
        newConnection.exportedObject = DiskJockeyXPC()

        newConnection.invalidationHandler = {
            NSLog("[DiskJockeyXPC] XPC connection invalidated")
        }
        newConnection.interruptionHandler = {
            NSLog("[DiskJockeyXPC] XPC connection interrupted")
        }

        newConnection.resume()
        return true
    }
}

// MARK: - Main

NSLog("[DiskJockeyXPC] Starting mach service: %@", machServiceName)

// Start the listener FIRST so macOS doesn't think we're hung
let delegate = ServiceDelegate()
let listener = NSXPCListener(machServiceName: machServiceName)
listener.delegate = delegate
listener.resume()
NSLog("[DiskJockeyXPC] Mach service listener active")

// Start the Go backend in the background
DispatchQueue.global().async {
    startBackendIfNeeded()

    if DiskJockeyXPC.sharedClient.connect() {
        NSLog("[DiskJockeyXPC] Connected to Go backend")
    } else {
        NSLog("[DiskJockeyXPC] Warning: could not connect to backend (will retry on first request)")
    }
}

NSLog("[DiskJockeyXPC] Entering run loop")
RunLoop.current.run()
