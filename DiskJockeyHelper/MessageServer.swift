import Foundation
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
        // Read 4-byte length prefix
        var lenBuf = [UInt8](repeating: 0, count: 4)
        let nLen = read(clientFD, &lenBuf, 4)
        guard nLen == 4 else {
            cleanupClientSocket(clientFD)
            return
        }
        let msgLen = Int(UInt32(bigEndian: lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
        // Read 1-byte type
        var typeBuf = [UInt8](repeating: 0, count: 1)
        let nType = read(clientFD, &typeBuf, 1)
        guard nType == 1 else {
            cleanupClientSocket(clientFD)
            return
        }
        let typeId = typeBuf[0]
        // Read protobuf payload
        var payloadBuf = [UInt8](repeating: 0, count: msgLen - 1)
        let nPayload = read(clientFD, &payloadBuf, msgLen - 1)
        guard nPayload == msgLen - 1 else {
            cleanupClientSocket(clientFD)
            return
        }
        let payload = Data(payloadBuf)
        handleMessage(typeId: typeId, payload: payload, clientFD: clientFD)
    }
    
    /// Handles a single message from a client socket
    private func handleMessage(typeId: UInt8, payload: Data, clientFD: Int32) {
        // For now, only handle CONNECT
        if typeId == Api_MessageType.connect.rawValue {
            handleConnect(payload: payload, clientFD: clientFD)
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
}
