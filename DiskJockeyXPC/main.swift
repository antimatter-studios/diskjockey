import Foundation
import DiskJockeyLibrary

/// XPC Bridge Service entry point.
/// Runs as a LaunchAgent with a mach service name.
/// Bridges fileprovider.proto requests from the File Provider extension
/// and desktop app to backend.proto requests sent to the Go backend over TCP.

let machServiceName = "com.antimatterstudios.diskjockey.xpc-bridge"

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

NSLog("[DiskJockeyXPC] Starting mach service: %@", machServiceName)

// Pre-connect to the Go backend so first request is fast
if DiskJockeyXPC.sharedClient.connect() {
    NSLog("[DiskJockeyXPC] Pre-connected to Go backend")
} else {
    NSLog("[DiskJockeyXPC] Warning: could not pre-connect to backend (will retry on first request)")
}

let delegate = ServiceDelegate()
let listener = NSXPCListener(machServiceName: machServiceName)
listener.delegate = delegate
listener.resume()

NSLog("[DiskJockeyXPC] Mach service listener active, entering run loop")
RunLoop.current.run()
