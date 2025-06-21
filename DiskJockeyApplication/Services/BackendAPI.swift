import Combine
import DiskJockeyLibrary
import Foundation
import Network
import SwiftProtobuf


public enum APIError: Error {
    case notConnected
    case invalidResponse
    case connectionFailed(Error? = nil)
    case requestFailed(Error)
    case encodingError
    case decodingError
    case protocolError(String)
}

public final class BackendAPIState: ObservableObject {
    @Published var connectionState: BackendAPI.ConnectionState = .disconnected
}

// Minimal async lock actor for critical section serialization
actor AsyncLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        // Wait until lock is available
        try await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if isLocked {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        } else {
            isLocked = true
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            isLocked = false
        }
    }
}

public class BackendAPI {
    public let state: BackendAPIState
    private let queue = DispatchQueue(label: "com.diskjockey.backend-api")
    private var connection: NWConnection?
    private var receiveTask: Task<Void, Never>?
    private let socketLock = AsyncLock()
    private let connectionStateSubject = CurrentValueSubject<ConnectionState, Never>(.disconnected)
    private let logger: LogRepository?

    public var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        connectionStateSubject.eraseToAnyPublisher()
    }
    
    private var reconnectHandler: (() async throws -> Void)?
    public func setReconnectHandler(_ handler: @escaping () async throws -> Void) {
        self.reconnectHandler = handler
    }

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

    private var connectionState: ConnectionState = .disconnected {
        didSet {
            DispatchQueue.main.async {
                self.state.connectionState = self.connectionState
            }
            connectionStateSubject.send(connectionState)
        }
    }
    // Use this method to safely update connectionState from non-actor closures
    public func setConnectionState(_ state: ConnectionState) async {
        self.connectionState = state
        // connectionStateSubject.send(state) is not needed here, as didSet will trigger it
        DispatchQueue.main.async {
            self.state.connectionState = self.connectionState
        }
    }
    public var currentConnectionState: ConnectionState { connectionState }

    // MARK: - Initialization

    public init(state: BackendAPIState, logger: LogRepository? = nil) {
        self.state = state
        self.logger = logger
        // Set initial state value
        DispatchQueue.main.async {
            self.state.connectionState = self.connectionState
        }
    }

    deinit {
        disconnect()
    }

    // MARK: - Logging
    private func log(_ msg: String) {
        print("BackendAPI: \(msg)")
        logger?.addLogEntry(LogEntry(message: msg, category: "backend"))
    }

    // MARK: - Connection Management
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
            try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
        }
        return false
    }

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
                Task {
                    self.log("Successfully connected to backend at \(host):\(port)")
                    await self.setConnectionState(.connected(info))
                    self.startReceiving()
                }

            case .failed(let error):
                Task {
                    self.log("Failed to connect to backend at \(host):\(port): \(error.localizedDescription)")
                    await self.setConnectionState(.failed(error))
                    self.cleanup()
                }

            case .cancelled:
                Task {
                    self.log("Connection to backend at \(host):\(port) cancelled")
                    await self.setConnectionState(.disconnected)
                    self.cleanup()
                }

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
            cancellableRef =
                connectionStatePublisher
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
                    try? await Task.sleep(nanoseconds: 20_000_000)  // 20ms polling
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
        messageType: Backend_MessageType
    ) async throws -> Response {
        return try await socketLock.withLock {
            self.log("Sending request: \(messageType)")

            guard connectionState.isConnected, let connection = connection else {
                throw APIError.notConnected
            }

            // Create the message
            var message = Backend_Message()
            message.type = messageType
            message.payload = try request.serializedData()
            let data = try message.serializedData()
            let size = Int32(data.count)
            var sizeData = withUnsafeBytes(of: size.bigEndian) { Data($0) }
            sizeData.append(data)

            // Uncomment to debug raw protobuf bytes:
            logRawDataIfEnabled("Sent sizeData", data: sizeData)
            // Send the data
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: sizeData, completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: APIError.requestFailed(error))
                    } else {
                        continuation.resume()
                    }
                })
            }

            // Wait for the response (blocking)
            let responseMessage = try await receiveMessage(expectedType: responseType, expectedMessageType: messageType)
            return responseMessage
        }
    }

    private func receiveMessage<Response: SwiftProtobuf.Message>(expectedType: Response.Type, expectedMessageType: Backend_MessageType) async throws -> Response {
        guard let connection = connection else { throw APIError.notConnected }

        // Read message size (4 bytes)
        let sizeData = try await receiveData(count: 4, from: connection)
        let size = sizeData.withUnsafeBytes { $0.load(as: Int32.self).bigEndian }

        // Read message payload
        let messageData = try await receiveData(count: Int(size), from: connection)
        logRawDataIfEnabled("Received messageData", data: messageData)
        print("[DEBUG] First 20 bytes (Swift): \(messageData.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " "))")
        do {
            // DECODE ENVELOPE: Backend_Message
            let envelope = try Backend_Message(serializedBytes: messageData)
//            if envelope.type != expectedType {
//                print("[PROTOBUF ERROR] Unexpected message type: got \(envelope.type), expected \(expectedMessageType)")
//                throw APIError.protocolError("Unexpected message type: got \(envelope.type), expected \(expectedMessageType)")
//            }
            // DECODE PAYLOAD
            return try expectedType.init(serializedBytes: envelope.payload)
        } catch {
            print("[PROTOBUF ERROR] Could not decode Protocol Buffer: \(error)")
            print("[PROTOBUF ERROR] Raw bytes (hex): \(messageData.map { String(format: "%02x", $0) }.joined())")
            if let text = String(data: messageData, encoding: .utf8) {
                print("[PROTOBUF ERROR] Raw bytes (utf8): \(text)")
            } else {
                print("[PROTOBUF ERROR] Raw bytes (utf8): <not valid utf8>")
            }
            throw error
        }
    }

    /// Helper for debugging raw protobuf bytes. Enable by uncommenting calls.
    private func logRawDataIfEnabled(_ label: String, data: Data) {
        // comment this out when you don't want it anymore
        print("[DEBUG] \(label): \(data as NSData)")
    }

    // MARK: - Private Methods

    private func startReceiving() {
        // No-op: stateless API does not need a receive loop for handlers
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
    }

    // MARK: - Mount Management

    public func addMount(_ mount: Mount) async throws {
        try await ensureConnectedAndPerform {
            let request = Backend_CreateMountRequest.with {
                $0.name = mount.name
                $0.diskType = mount.diskType.rawValue
                $0.config = {
                    var config: [String: String] = [:]
                    if !mount.path.isEmpty { config["path"] = mount.path }
                    if !mount.remotePath.isEmpty { config["remotePath"] = mount.remotePath }
                    return config
                }()
            }
            _ = try await self.sendRequest(
                request,
                responseType: Backend_CreateMountResponse.self,
                messageType: .createMountRequest
            )
            self.log("Created mount: \(mount.name)")
        }
    }

    public func removeMount(id: UInt32) async throws {
        try await ensureConnectedAndPerform {
            let request = Backend_DeleteMountRequest.with {
                $0.mountID = id
            }
            _ = try await self.sendRequest(
                request,
                responseType: Backend_DeleteMountResponse.self,
                messageType: .deleteMountRequest
            )
            self.log("Deleted mountID: \(id)")
        }
    }

    public func mount(id: UInt32) async throws {
        try await ensureConnectedAndPerform {
            let request = Backend_MountRequest.with {
                $0.mountID = id
            }
            _ = try await self.sendRequest(
                request,
                responseType: Backend_MountResponse.self,
                messageType: .mountRequest
            )
            self.log("Mounted mountID: \(id)")
        }
    }

    public func unmount(id: UInt32) async throws {
        try await ensureConnectedAndPerform {
            let request = Backend_UnmountRequest.with {
                $0.mountID = id
            }
            _ = try await self.sendRequest(
                request,
                responseType: Backend_UnmountResponse.self,
                messageType: .unmountRequest
            )
            self.log("Unmounted mountID: \(id)")
        }
    }

    public func listMounts() async throws -> [Mount] {
        return try await ensureConnectedAndPerform {
            let request = Backend_ListMountsRequest()
            let response: Backend_ListMountsResponse = try await self.sendRequest(
                request,
                responseType: Backend_ListMountsResponse.self,
                messageType: .listMountsRequest
            )

            let mounts = response.mounts.map { apiMount in
                Mount(
                    id: UUID(),  // Generate a new UUID since we don't have one from the server
                    diskType: DiskTypeEnum(rawValue: apiMount.diskType.lowercased()) ?? .localdirectory,
                    name: apiMount.name,
                    path: "",  // Not provided in MountInfo
                    remotePath: "",  // Not provided in MountInfo
                    isMounted: false,  // Default to false since we don't have this info
                    lastAccessed: nil,  // Not provided in MountInfo
                    metadata: apiMount.config  // Using config map as metadata
                )
            }
            self.log("Listed \(mounts.count) mounts")
            return mounts
        }
    }

    // MARK: - DiskType Management

    /// Fetches the list of available diskTypes, auto-reconnecting if needed.
    /// - Returns: An array of DiskType objects
    public func listDiskTypes() async throws -> [DiskType] {
        return try await ensureConnectedAndPerform {
            let request = Backend_ListDiskTypesRequest()
            let response: Backend_ListDiskTypesResponse = try await self.sendRequest(
                request,
                responseType: Backend_ListDiskTypesResponse.self,
                messageType: .listDiskTypesRequest
            )
            let diskTypes = response.diskTypes.map { apiDiskType in
                DiskType(
                    name: apiDiskType.name,
                    version: "1.0.0",
                    description: apiDiskType.description_p
                )
            }
            self.log("Listed \(diskTypes) diskTypes")
            return diskTypes
        }
    }
}
