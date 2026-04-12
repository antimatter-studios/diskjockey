import Foundation
import Network
import DiskJockeyLibrary
import SwiftProtobuf

/// TCP client that connects to the Go backend and sends/receives
/// backend.proto messages using the same size-prefixed envelope protocol.
class BackendTCPClient {
    private let appGroupID = "group.com.antimatterstudios.diskjockey"
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.diskjockey.xpc.tcp")

    /// Discover the backend port from the shared app group container.
    private func discoverPort() -> Int? {
        // Try port file first
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            let portFileURL = containerURL.appendingPathComponent("backend.port")
            if let contents = try? String(contentsOf: portFileURL, encoding: .utf8),
               let port = Int(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return port
            }
        }

        // Fall back to UserDefaults
        if let defaults = UserDefaults(suiteName: appGroupID) {
            let port = defaults.integer(forKey: "backend_port")
            if port > 0 { return port }
        }

        return nil
    }

    /// Connect to the Go backend. Returns true on success.
    func connect() -> Bool {
        guard let port = discoverPort() else {
            NSLog("[BackendTCPClient] Cannot discover backend port")
            return false
        }

        let conn = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(integerLiteral: UInt16(port)),
            using: .tcp
        )

        let semaphore = DispatchSemaphore(value: 0)
        var connected = false

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connected = true
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }

        conn.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 5.0)

        guard connected else {
            conn.cancel()
            NSLog("[BackendTCPClient] Failed to connect to backend on port %d", port)
            return false
        }

        self.connection = conn

        // Send CONNECT handshake with FILE_PROVIDER role
        do {
            var req = Backend_ConnectRequest()
            req.role = .fileProvider
            try sendRequestSync(req, messageType: .connect)
            // Read and discard the ConnectResponse
            let _ = try receiveMessageSync()
            NSLog("[BackendTCPClient] Connected to backend on port %d", port)
            return true
        } catch {
            NSLog("[BackendTCPClient] Handshake failed: %@", error.localizedDescription)
            conn.cancel()
            self.connection = nil
            return false
        }
    }

    /// Ensure we have an active connection, reconnecting if needed.
    private func ensureConnected() throws {
        if connection == nil || connection?.state != .ready {
            connection?.cancel()
            connection = nil
            guard connect() else {
                throw XPCBridgeError.backendUnavailable
            }
        }
    }

    /// Send a request and receive the response synchronously.
    func sendRequest<Req: SwiftProtobuf.Message>(
        _ request: Req,
        messageType: Backend_MessageType
    ) throws -> (Backend_MessageType, Data) {
        try ensureConnected()
        try sendRequestSync(request, messageType: messageType)
        return try receiveMessageSync()
    }

    // MARK: - Low-level protocol

    private func sendRequestSync<Req: SwiftProtobuf.Message>(
        _ request: Req,
        messageType: Backend_MessageType
    ) throws {
        guard let conn = connection else {
            throw XPCBridgeError.backendUnavailable
        }

        var message = Backend_Message()
        message.type = messageType
        message.payload = try request.serializedData()
        let messageData = try message.serializedData()

        // Build frame: 4-byte big-endian size + message
        var size = Int32(messageData.count).bigEndian
        var frame = Data(bytes: &size, count: 4)
        frame.append(messageData)

        let semaphore = DispatchSemaphore(value: 0)
        var sendError: Error?

        conn.send(content: frame, completion: .contentProcessed { error in
            sendError = error
            semaphore.signal()
        })

        _ = semaphore.wait(timeout: .now() + 10.0)
        if let error = sendError {
            throw XPCBridgeError.sendFailed(error)
        }
    }

    private func receiveMessageSync() throws -> (Backend_MessageType, Data) {
        guard let conn = connection else {
            throw XPCBridgeError.backendUnavailable
        }

        // Read 4-byte size header
        let sizeData = try receiveExact(conn: conn, count: 4)
        let size = sizeData.withUnsafeBytes { $0.load(as: Int32.self).bigEndian }

        guard size > 0, size < 100 * 1024 * 1024 else {
            throw XPCBridgeError.invalidResponse
        }

        // Read message body
        let messageData = try receiveExact(conn: conn, count: Int(size))

        let envelope = try Backend_Message(serializedBytes: messageData)
        return (envelope.type, envelope.payload)
    }

    private func receiveExact(conn: NWConnection, count: Int) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        var recvError: Error?

        conn.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            result = data
            recvError = error
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 30.0)

        if let error = recvError {
            throw XPCBridgeError.receiveFailed(error)
        }

        guard let data = result, data.count == count else {
            throw XPCBridgeError.invalidResponse
        }

        return data
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }
}

enum XPCBridgeError: Error {
    case backendUnavailable
    case sendFailed(Error)
    case receiveFailed(Error)
    case invalidResponse
}
