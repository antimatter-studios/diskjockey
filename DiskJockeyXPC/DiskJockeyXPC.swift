import Foundation
import DiskJockeyLibrary
import SwiftProtobuf

/// XPC-exported object that handles requests from the File Provider extension.
/// Translates fileprovider.proto requests into backend.proto requests,
/// sends them to the Go backend over TCP, and returns the translated response.
class DiskJockeyXPC: NSObject, FileProviderXPCProtocol {
    static let sharedClient = BackendTCPClient()
    private var backendClient: BackendTCPClient { DiskJockeyXPC.sharedClient }

    func handleRequest(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        // Parse the fileprovider.proto request
        guard let request = try? Diskjockey_Fileprovider_FileProviderRequest(serializedBytes: data) else {
            NSLog("[DiskJockeyXPC] Failed to parse FileProviderRequest")
            reply(makeErrorResponse("Failed to parse request").serialized())
            return
        }

        let mountIDString = request.mountID
        guard let mountID = UInt32(mountIDString) else {
            NSLog("[DiskJockeyXPC] Invalid mount_id: %@", mountIDString)
            reply(makeErrorResponse("Invalid mount_id: \(mountIDString)").serialized())
            return
        }

        NSLog("[DiskJockeyXPC] Request for mount %d: %@", mountID, String(describing: request.requestType))

        do {
            switch request.requestType {
            case .list(let listReq):
                reply(try handleList(mountID: mountID, path: listReq.path).serialized())

            case .stat(let statReq):
                reply(try handleStat(mountID: mountID, path: statReq.path).serialized())

            case .read(let readReq):
                reply(try handleRead(mountID: mountID, path: readReq.path).serialized())

            case .none:
                reply(makeErrorResponse("Empty request (no request_type set)").serialized())
            }
        } catch {
            NSLog("[DiskJockeyXPC] Error: %@", error.localizedDescription)
            reply(makeErrorResponse(error.localizedDescription).serialized())
        }
    }

    // MARK: - Request Handlers

    private func handleList(mountID: UInt32, path: String) throws -> Diskjockey_Fileprovider_FileProviderResponse {
        var req = Backend_ListDirRequest()
        req.mountID = mountID
        req.path = path

        let (_, payload) = try backendClient.sendRequest(req, messageType: .listDirRequest)
        let backendResp = try Backend_ListDirResponse(serializedBytes: payload)

        var response = Diskjockey_Fileprovider_FileProviderResponse()
        if !backendResp.error.isEmpty {
            response.error = .with { $0.message = backendResp.error }
        } else {
            response.list = .with {
                $0.files = backendResp.files.map { f in
                    Diskjockey_Fileprovider_FileInfo.with {
                        $0.name = f.name
                        $0.isDirectory = f.isDir
                        $0.size = f.size
                    }
                }
            }
        }
        return response
    }

    private func handleStat(mountID: UInt32, path: String) throws -> Diskjockey_Fileprovider_FileProviderResponse {
        var req = Backend_StatRequest()
        req.mountID = mountID
        req.path = path

        let (_, payload) = try backendClient.sendRequest(req, messageType: .statRequest)
        let backendResp = try Backend_StatResponse(serializedBytes: payload)

        var response = Diskjockey_Fileprovider_FileProviderResponse()
        if !backendResp.error.isEmpty {
            response.error = .with { $0.message = backendResp.error }
        } else if backendResp.hasInfo {
            response.stat = .with {
                $0.file = .with {
                    $0.name = backendResp.info.name
                    $0.isDirectory = backendResp.info.isDir
                    $0.size = backendResp.info.size
                }
            }
        }
        return response
    }

    private func handleRead(mountID: UInt32, path: String) throws -> Diskjockey_Fileprovider_FileProviderResponse {
        var req = Backend_ReadFileRequest()
        req.mountID = mountID
        req.path = path

        let (_, payload) = try backendClient.sendRequest(req, messageType: .readFileRequest)
        let backendResp = try Backend_ReadFileResponse(serializedBytes: payload)

        var response = Diskjockey_Fileprovider_FileProviderResponse()
        if !backendResp.error.isEmpty {
            response.error = .with { $0.message = backendResp.error }
        } else {
            response.read = .with {
                $0.data = backendResp.data
            }
        }
        return response
    }

    // MARK: - Helpers

    private func makeErrorResponse(_ message: String) -> Diskjockey_Fileprovider_FileProviderResponse {
        var response = Diskjockey_Fileprovider_FileProviderResponse()
        response.error = .with { $0.message = message }
        return response
    }
}

private extension Diskjockey_Fileprovider_FileProviderResponse {
    func serialized() -> Data {
        return (try? self.serializedData()) ?? Data()
    }
}
