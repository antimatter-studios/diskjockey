import Foundation
import DiskJockeyLibrary

/// Simple test harness for XPC communication. Run this in the main app or helper to verify the XPC server is working.
func testFileProviderXPCService() {
    let connection = NSXPCConnection(machServiceName: "com.antimatterstudios.diskjockey.xpc", options: [])
    connection.remoteObjectInterface = NSXPCInterface(with: FileProviderXPCProtocol.self)
    connection.resume()
    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        print("XPC error: \(error)")
    } as? DiskJockeyLibrary.FileProviderXPCProtocol
    let dummyRequest = Data() // TODO: Replace with real serialized FileProviderRequest
    proxy?.handleRequest(dummyRequest, withReply: { response in
        print("Received XPC response: \(response)")
    })
}
