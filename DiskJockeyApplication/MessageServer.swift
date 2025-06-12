import Foundation
import SwiftProtobuf
import DiskJockeyHelperLibrary

/// MessageServer: Accepts new client sockets and dispatches messages
class MessageServer {
    private var clientSockets: [Int32: DispatchSourceRead] = [:]
    private let clientSocketsLock = NSLock()
    
    // Store references to keep API objects alive
    private var applicationApi: ApplicationAPI?
    private var backendApi: BackendAPI?
    private var fileProviderApi: FileProviderAPI?
    
    /// Called by the TCPListener accept handler
    func acceptClientSocket(_ clientFD: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: .global())
        source.setEventHandler { [weak self] in
            self?.handleReadableSocket(clientFD)
        }
        source.setCancelHandler {
            close(clientFD)
        }
        clientSocketsLock.lock()
        clientSockets[clientFD] = source
        clientSocketsLock.unlock()
        source.resume()
    }
    
    /// Handles readable events on a client socket
    private func handleReadableSocket(_ clientFD: Int32) {
        guard let (typeId, payload) = receiveMessage(clientFD: clientFD) else {
            cleanupClientSocket(clientFD)
            return
        }
        handleMessage(typeId: typeId, payload: payload, clientFD: clientFD)
    }

    /// Handles a single message from a client socket
    private func handleMessage(typeId: UInt8, payload: Data, clientFD: Int32) {
        if typeId == Api_MessageType.connect.rawValue {
            handleConnect(payload: payload, clientFD: clientFD)
            // After handshake, send ListPluginsRequest
            var req = Api_ListPluginsRequest()
            sendMessage(type: Api_MessageType.listPluginsRequest, message: req, clientFD: clientFD)
        } else if typeId == Api_MessageType.listPluginsRequest.rawValue {
            // Handle ListPluginsResponse
            do {
                let resp = try Api_ListPluginsResponse(serializedData: payload)
                print("Active plugins:")
                for plugin in resp.plugins {
                    print(" - \(plugin.name)")
                }
                // Notify UI
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("PluginsListUpdated"), object: nil, userInfo: ["plugins": resp.plugins])
                }
            } catch {
                NSLog("Failed to decode ListPluginsResponse: %@", error.localizedDescription)
            }
        } else {
            // TODO: Route to appropriate API object
        }
    }
    
    /// Handles CONNECT handshake
    private func handleConnect(payload: Data, clientFD: Int32) {
        // Parse the protobuf CONNECT message
        guard let connectMsg = try? Api_ConnectRequest(serializedBytes: payload) else {
            cleanupClientSocket(clientFD)
            return
        }
        // Identify role and create appropriate API object
        switch connectMsg.role {
        case .app:
            self.applicationApi = ApplicationAPI(clientFD: clientFD)
        case .backend:
            self.backendApi = BackendAPI(clientFD: clientFD)
        case .fileProvider:
            self.fileProviderApi = FileProviderAPI(clientFD: clientFD)
        default:
            break
        }
    }
    
    /// Cleans up and closes a client socket
    private func cleanupClientSocket(_ clientFD: Int32) {
        clientSocketsLock.lock()
        if let source = clientSockets.removeValue(forKey: clientFD) {
            source.cancel()
        } else {
            close(clientFD)
        }
        clientSocketsLock.unlock()
    }

    public func stop() {
        clientSocketsLock.lock()
        for (_, source) in clientSockets {
            source.cancel() // This will also close the socket via setCancelHandler
        }
        clientSockets.removeAll()
        clientSocketsLock.unlock()
        applicationApi = nil
        backendApi = nil
        fileProviderApi = nil
    }

    /// Sends a framed protobuf message to the backend
    private func sendMessage(type: Api_MessageType, message: SwiftProtobuf.Message, clientFD: Int32) {
        do {
            let payload = try message.serializedData()
            var data = Data()
            var length = UInt32(payload.count + 1).bigEndian
            data.append(Data(bytes: &length, count: 4))
            data.append(UInt8(type.rawValue))
            data.append(payload)
            _ = data.withUnsafeBytes { ptr in
                write(clientFD, ptr.baseAddress, data.count)
            }
        } catch {
            NSLog("Failed to serialize message: %@", error.localizedDescription)
        }
    }

    /// Reads a framed protobuf message from the socket
    private func receiveMessage(clientFD: Int32) -> (UInt8, Data)? {
        var lenBuf = [UInt8](repeating: 0, count: 4)
        let nLen = read(clientFD, &lenBuf, 4)
        guard nLen == 4 else { return nil }

        let msgLen = Int(UInt32(bigEndian: lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
        var typeBuf = [UInt8](repeating: 0, count: 1)
        let nType = read(clientFD, &typeBuf, 1)
        guard nType == 1 else { return nil }

        let typeId = typeBuf[0]
        var payloadBuf = [UInt8](repeating: 0, count: msgLen - 1)
        let nPayload = read(clientFD, &payloadBuf, msgLen - 1)
        guard nPayload == msgLen - 1 else { return nil }
        
        let payload = Data(payloadBuf)
        return (typeId, payload)
    }
}

