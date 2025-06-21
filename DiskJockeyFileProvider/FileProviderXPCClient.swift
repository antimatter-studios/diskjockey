import Foundation
import DiskJockeyLibrary

class FileProviderXPCClient {
    private let connection: NSXPCConnection

    init() {
        // The mach service name must match the helper/app's XPC registration
        self.connection = NSXPCConnection(machServiceName: "com.antimatterstudios.diskjockey.xpc", options: [])
        self.connection.remoteObjectInterface = NSXPCInterface(with: FileProviderXPCProtocol.self)
        self.connection.resume()
    }

    func sendRequest(_ requestData: Data, completion: @escaping (Data?) -> Void) {
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            print("XPC error: \(error)")
            completion(nil)
        } as? FileProviderXPCProtocol
        proxy?.handleRequest(requestData, withReply: { responseData in
            completion(responseData)
        })
    }

    // Example: List directory for a given mount ID and path
    func listDirectory(mountID: String, path: String, completion: @escaping ([String]) -> Void) {
        // --- Begin generated code integration ---
        // import DiskJockeyLibrary // for FileProviderRequest/Response (SwiftProtobuf)
        // var req = FileProviderRequest()
        // req.mountID = mountID
        // req.list = ListRequest.with { $0.path = path }
        // let data = try? req.serializedData()
        // sendRequest(data ?? Data()) { responseData in
        //     guard let responseData = responseData,
        //           let response = try? FileProviderResponse(serializedData: responseData),
        //           case .list(let listResp) = response.responseType else {
        //         completion([])
        //         return
        //     }
        //     let filenames = listResp.files.map { $0.name }
        //     completion(filenames)
        // }
        // --- End generated code integration ---
        // For now, decode the stubbed JSON response
        struct StubFileInfo: Codable { let name: String; let isDirectory: Bool; let size: Int64; let mtime: Int64 }
        sendRequest(Data()) { responseData in
            guard let responseData = responseData,
                  let files = try? JSONDecoder().decode([StubFileInfo].self, from: responseData) else {
                print("[XPCClient] Failed to decode directory listing")
                completion([])
                return
            }
            let filenames = files.map { $0.name }
            print("[XPCClient] Directory listing: \(filenames)")
            completion(filenames)
        }
    }
}

