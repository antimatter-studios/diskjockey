import Foundation
import DiskJockeyLibrary

class BackendManager: ObservableObject {
    private var backendProcess: Process?
    private var tcpListener: TCPListener?
    private var messageServer: MessageServer?

    // Launch backend and fetch plugins
    func startBackendAndConnect(completion: @escaping ([Plugin]) -> Void) {
        // Start the message server
        messageServer = MessageServer()
        // Start the TCP listener on a random port (0 = let OS choose)
        tcpListener = TCPListener(port: 0) { [weak self] clientFD in
            self?.messageServer?.acceptClientSocket(clientFD)
        }
        guard let actualPort = tcpListener?.actualPort else {
            print("Failed to get TCP listener port")
            completion([])
            return
        }
        print("TCP listener started on port \(actualPort)")
        launchBackend(helperPort: actualPort)
        // Listen for plugin list notification
        NotificationCenter.default.addObserver(forName: NSNotification.Name("PluginsListUpdated"), object: nil, queue: .main) { notification in
            if let pluginInfos = notification.userInfo?["plugins"] as? [Api_PluginTypeInfo] {
                let plugins = pluginInfos.map { Plugin(name: $0.name, description: $0.description_p) }
                completion(plugins)
            }
        }
    }

    private func launchBackend(helperPort: Int) {
        let fileManager = FileManager.default
        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        guard let backendURL = Bundle.main.url(forResource: "diskjockey-backend", withExtension: nil) else {
            print("Failed to find backend executable")
            return
        }
        let process = Process()
        process.executableURL = backendURL
        process.arguments = [
            "--config-dir", appSupportDir.appendingPathComponent("DiskJockey").path,
            "--helper-port", String(helperPort)
        ]
        process.terminationHandler = { _ in
            print("Backend process terminated")
        }
        do {
            try process.run()
            backendProcess = process
            print("Launched backend with --helper-port \(helperPort)")
        } catch {
            print("Failed to launch backend: \(error)")
        }
    }
}
