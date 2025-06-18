import Foundation
import Combine
import Network
import SwiftProtobuf
import DiskJockeyLibrary

public enum APIError: Error {
    case notConnected
    case invalidResponse
    case connectionFailed(Error? = nil)
    case requestFailed(Error)
    case encodingError
    case decodingError
    case protocolError(String)
}

open class BackendAPI: ObservableObject {
    // ...
    private var reconnectHandler: (() async throws -> Void)?
    public func setReconnectHandler(_ handler: @escaping () async throws -> Void) {
        self.reconnectHandler = handler
    }
    private let logger: LogRepository?
    // MARK: - Types
    
    public struct ConnectionInfo: Equatable {
        public let host: String
        public let port: UInt16
        
        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }
    }
    
    public enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(ConnectionInfo)
        case failed(Error)
        
        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
        
        public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected):
                return true
            case (.connecting, .connecting):
                return true
            case (.connected(let lhsInfo), .connected(let rhsInfo)):
                return lhsInfo == rhsInfo
            case (.failed, .failed):
                // Errors don't conform to Equatable, so we consider all errors equal
                return true
            default:
                return false
            }
        }
    }
    
    // MARK: - Properties
    
    private let queue = DispatchQueue(label: "com.diskjockey.backend-api")
    private var connection: NWConnection?
    private var messageHandlers: [Api_MessageType: (Data) -> Void] = [:]
    private var receiveTask: Task<Void, Never>?
    
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    public var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        $connectionState.eraseToAnyPublisher()
    }
    
    // MARK: - Initialization
    
    public init(logger: LogRepository? = nil) {
        self.logger = logger
    }
    
    deinit {
        disconnect()
    }

    // MARK: - Logging
    private func log(_ msg: String) {
        print("BackendAPI: \(msg)")
        logger?.addLogEntry(LogEntry(message: msg, category: "backend"))
    }
    
    // MARK: - Public Methods
    
    // MARK: - Mount Management
    
    public func listMounts() async throws -> [Mount] {
        let request = Api_ListMountsRequest()
        let response: Api_ListMountsResponse = try await sendRequest(
            request,
            responseType: Api_ListMountsResponse.self,
            messageType: .listMountsRequest
        )
        
        return response.mounts.map { apiMount in
            Mount(
                id: UUID(), // Generate a new UUID since we don't have one from the server
                name: apiMount.name,
                path: "", // Not provided in MountInfo
                remotePath: "", // Not provided in MountInfo
                isMounted: false, // Default to false since we don't have this info
                type: MountType(rawValue: apiMount.pluginType.lowercased()) ?? .other,
                lastAccessed: nil, // Not provided in MountInfo
                metadata: apiMount.config // Using config map as metadata
            )
        }
    }
    
    // MARK: - Plugin Management
    
    /// Ensures connection, reconnects if needed, then performs the given async action.
    public func ensureConnectedAndPerform<T>(action: @escaping () async throws -> T) async throws -> T {
        if case .connected = self.connectionState {
            return try await action()
        } else if let reconnect = self.reconnectHandler {
            try await reconnect()
            let connected = await waitForConnection(timeout: 10)
            if connected {
                return try await action()
            } else {
                throw APIError.notConnected
            }
        } else {
            throw APIError.notConnected
        }
    }
    
    /// Waits for the backend API to connect, up to the given timeout (in seconds).
    private func waitForConnection(timeout: TimeInterval) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if case .connected = self.connectionState {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }
        return false
    }
    
    /// Fetches the list of available plugins, auto-reconnecting if needed.
    /// - Returns: An array of Plugin objects
    public func listPlugins() async throws -> [Plugin] {
        return try await ensureConnectedAndPerform {
            let request = Api_ListPluginsRequest()
            let response: Api_ListPluginsResponse = try await self.sendRequest(
                request,
                responseType: Api_ListPluginsResponse.self,
                messageType: .listPluginsRequest
            )
            return response.plugins.map { apiPlugin in
                Plugin(
                    name: apiPlugin.name,
                    version: "1.0.0",
                    description: apiPlugin.description_p
                )
            }
        }
    }
    
    // MARK: - Connection Management
    
    public func connect(host: String = "localhost", port: Int) async throws {
        // Cancel any existing connection
        disconnect()
        
        log("Attempting to connect to backend at \(host):\(port)")
        connectionState = .connecting
        
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port)),
            using: .tcp
        )
        
        self.connection = connection
        
        // Set up state update handler
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            switch state {
            case .ready:
                let info = ConnectionInfo(host: host, port: UInt16(port))
                self.log("Successfully connected to backend at \(host):\(port)")
                self.connectionState = .connected(info)
                self.startReceiving()
                
            case .failed(let error):
                self.log("Failed to connect to backend at \(host):\(port): \(error.localizedDescription)")
                self.connectionState = .failed(error)
                self.cleanup()
                
            case .cancelled:
                self.log("Connection to backend at \(host):\(port) cancelled")
                self.connectionState = .disconnected
                self.cleanup()
                
            default:
                break
            }
        }
        
        // Start the connection
        connection.start(queue: queue)
        
        // Wait for connection to be established or fail
        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            var cancellableRef: AnyCancellable?
            cancellableRef = connectionStatePublisher
                .first { state in
                    if case .connected = state { return true }
                    if case .failed = state { return true }
                    return false
                }
                .sink { state in
                    guard !didResume else { return }
                    didResume = true
                    if case .connected = state {
                        continuation.resume()
                    } else if case .failed(let error) = state {
                        continuation.resume(throwing: APIError.connectionFailed(error))
                    } else {
                        continuation.resume(throwing: APIError.connectionFailed())
                    }
                    cancellableRef = nil
                }

            // Resume continuation if the task is cancelled
            Task {
                while !didResume {
                    try? await Task.sleep(nanoseconds: 20_000_000) // 20ms polling
                    if Task.isCancelled, !didResume {
                        didResume = true
                        cancellableRef?.cancel()
                        cancellableRef = nil
                        continuation.resume(throwing: CancellationError())
                        break
                    }
                }
            }
        }
    }
    
    public func disconnect() {
        connection?.cancel()
        cleanup()
    }
    
    public func sendRequest<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
        _ request: Request,
        responseType: Response.Type,
        messageType: Api_MessageType
    ) async throws -> Response {
        guard connectionState.isConnected, let connection = connection else {
            throw APIError.notConnected
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            do {
                // Create the message
                var message = Api_Message()
                message.type = messageType
                message.payload = try request.serializedData()
                
                // Serialize the message
                let data = try message.serializedData()
                let size = Int32(data.count)
                var sizeData = withUnsafeBytes(of: size.bigEndian) { Data($0) }
                sizeData.append(data)
                
                // Send the data
                connection.send(
                    content: sizeData,
                    completion: .contentProcessed { [weak self] error in
                        if let error = error {
                            continuation.resume(throwing: APIError.requestFailed(error))
                            return
                        }
                        
                        // Set up a one-time handler for the response
                        self?.messageHandlers[messageType] = { data in
                            do {
                                let response = try responseType.init(serializedBytes: data)
                                continuation.resume(returning: response)
                            } catch {
                                continuation.resume(throwing: APIError.decodingError)
                            }
                        }
                    }
                )
            } catch {
                continuation.resume(throwing: APIError.encodingError)
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func startReceiving() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self = self, let connection = self.connection else { return }
            
            while !Task.isCancelled {
                do {
                    // Read message size (4 bytes)
                    let sizeData = try await self.receiveData(count: 4, from: connection)
                    let size = sizeData.withUnsafeBytes { $0.load(as: Int32.self).bigEndian }
                    
                    // Read message payload
                    let messageData = try await self.receiveData(count: Int(size), from: connection)
                    let message = try Api_Message(serializedBytes: messageData)
                    
                    // Call the appropriate handler
                    if let handler = self.messageHandlers[message.type] {
                        handler(message.payload)
                        self.messageHandlers.removeValue(forKey: message.type)
                    }
                } catch {
                    if !Task.isCancelled {
                        print("Error receiving data: \(error)")
                    }
                    break
                }
            }
        }
    }
    
    private func receiveData(count: Int, from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: count,
                maximumLength: count
            ) { data, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: APIError.invalidResponse)
                }
            }
        }
    }
    
    private func cleanup() {
        receiveTask?.cancel()
        receiveTask = nil
        
        connection?.cancel()
        connection = nil
        
        if case .connected = connectionState {
            connectionState = .disconnected
        }
        
        // Cancel all pending handlers
        messageHandlers.values.forEach { handler in
            handler(Data()) // Send empty data to unblock any waiting tasks
        }
        messageHandlers.removeAll()
    }
}
