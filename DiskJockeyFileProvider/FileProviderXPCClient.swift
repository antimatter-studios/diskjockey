import Foundation
import DiskJockeyLibrary

class FileProviderXPCClient {
    private var connection: NSXPCConnection?

    private func getConnection() -> NSXPCConnection {
        if let conn = connection { return conn }

        // Connect to the mach service registered by the XPC bridge LaunchAgent
        let conn = NSXPCConnection(machServiceName: "com.antimatterstudios.diskjockey.xpc-bridge")
        conn.remoteObjectInterface = NSXPCInterface(with: FileProviderXPCProtocol.self)

        conn.invalidationHandler = { [weak self] in
            NSLog("[FileProviderXPCClient] Connection invalidated")
            self?.connection = nil
        }
        conn.interruptionHandler = { [weak self] in
            NSLog("[FileProviderXPCClient] Connection interrupted")
            self?.connection = nil
        }

        conn.resume()
        self.connection = conn
        return conn
    }

    private func sendRequest(_ requestData: Data, completion: @escaping (Data?) -> Void) {
        let conn = getConnection()
        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            NSLog("[FileProviderXPCClient] XPC error: %@", error.localizedDescription)
            completion(nil)
        } as? FileProviderXPCProtocol

        proxy?.handleRequest(requestData, withReply: { responseData in
            completion(responseData)
        })
    }

    // MARK: - Typed API

    func listDirectory(mountID: String, path: String, completion: @escaping (Diskjockey_Fileprovider_FileProviderResponse?) -> Void) {
        var req = Diskjockey_Fileprovider_FileProviderRequest()
        req.mountID = mountID
        req.list = Diskjockey_Fileprovider_ListRequest.with { $0.path = path }

        guard let data = try? req.serializedData() else {
            completion(nil)
            return
        }

        sendRequest(data) { responseData in
            guard let responseData = responseData,
                  let response = try? Diskjockey_Fileprovider_FileProviderResponse(serializedBytes: responseData) else {
                completion(nil)
                return
            }
            completion(response)
        }
    }

    func stat(mountID: String, path: String, completion: @escaping (Diskjockey_Fileprovider_FileProviderResponse?) -> Void) {
        var req = Diskjockey_Fileprovider_FileProviderRequest()
        req.mountID = mountID
        req.stat = Diskjockey_Fileprovider_StatRequest.with { $0.path = path }

        guard let data = try? req.serializedData() else {
            completion(nil)
            return
        }

        sendRequest(data) { responseData in
            guard let responseData = responseData,
                  let response = try? Diskjockey_Fileprovider_FileProviderResponse(serializedBytes: responseData) else {
                completion(nil)
                return
            }
            completion(response)
        }
    }

    func readFile(mountID: String, path: String, completion: @escaping (Diskjockey_Fileprovider_FileProviderResponse?) -> Void) {
        var req = Diskjockey_Fileprovider_FileProviderRequest()
        req.mountID = mountID
        req.read = Diskjockey_Fileprovider_ReadRequest.with { $0.path = path }

        guard let data = try? req.serializedData() else {
            completion(nil)
            return
        }

        sendRequest(data) { responseData in
            guard let responseData = responseData,
                  let response = try? Diskjockey_Fileprovider_FileProviderResponse(serializedBytes: responseData) else {
                completion(nil)
                return
            }
            completion(response)
        }
    }
}
