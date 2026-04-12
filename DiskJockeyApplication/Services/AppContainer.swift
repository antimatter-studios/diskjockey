import Foundation
import Combine
import DiskJockeyLibrary

@MainActor
public final class AppContainer: ObservableObject {
    // MARK: - Logging
    public let appLogModel: AppLogModel
    public var appLogger: AppLogger { appLogModel as! AppLogger }
    // MARK: - Public Properties

    /// The disk type repository for managing diskTypes
    public let diskTypeRepository: DiskTypeRepository

    /// The mount repository for managing mounts
    public let mountRepository: MountRepository

    /// The log repository for managing logs
    public let logRepository: LogRepository

    /// Current backend connection state
    @Published public private(set) var connectionState: BackendAPI.ConnectionState = .disconnected

    /// Current error state, if any
    @Published public private(set) var error: Error?

    // MARK: - Private Properties

    private let serviceManager: BackendServiceManager
    public let apiState: BackendAPIState
    public let backendAPI: BackendAPI
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    public init() {
        // Initialize state and API
        self.apiState = BackendAPIState()
        self.backendAPI = BackendAPI(state: self.apiState)
        self.connectionState = .disconnected

        // Initialize repositories with the API
        self.diskTypeRepository = DiskTypeRepository(api: self.backendAPI)
        self.mountRepository = MountRepository(api: self.backendAPI)
        self.logRepository = LogRepository(api: self.backendAPI)

        // Initialize logger
        self.appLogModel = AppLogModel(logRepository: self.logRepository)

        // Initialize the service manager (LaunchAgent-based)
        self.serviceManager = BackendServiceManager(logger: self.logRepository)

        // Set reconnect handler for backendAPI
        Task { await self.backendAPI.setReconnectHandler { [weak self] in
            print("Backend disconnected, attempting to reconnect...")
            await self?.connectToBackend()
        }}

        // Observe connection state changes from apiState
        self.apiState.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
            }
            .store(in: &cancellables)

        setupAPIObservation()
    }

    // MARK: - Public Methods

    /// Ensures the backend is connected, reconnecting if needed, then performs the given async action.
    public func ensureBackendConnectedAndPerform(_ action: @escaping () async throws -> Void) {
        Task {
            if case .connected = self.connectionState {
                try? await action()
            } else {
                print("Backend not connected, attempting to connect...")
                await self.connectToBackend()
                let connected = await waitForConnection(timeout: 10)
                if connected {
                    try? await action()
                } else {
                    self.error = NSError(domain: "AppContainer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to backend"])
                }
            }
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

    /// Register the LaunchAgent and connect to the backend.
    public func startBackend() {
        Task {
            serviceManager.register()
            await connectToBackend()
        }
    }

    /// Do NOT stop the backend on app quit — it runs independently for the File Provider.
    public func stopBackend() {
        // Intentionally empty. The backend keeps running as a LaunchAgent.
        // Call serviceManager.unregister() only if the user explicitly wants to stop it.
    }

    // MARK: - Private Methods

    private var isConnecting = false

    private func connectToBackend() async {
        guard !isConnecting else {
            NSLog("[AppContainer] connectToBackend already in progress, skipping")
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        NSLog("[AppContainer] connectToBackend called")
        guard let port = await serviceManager.discoverPort() else {
            NSLog("[AppContainer] Could not discover backend port")
            self.error = NSError(domain: "AppContainer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not discover backend port. Is the backend running?"
            ])
            return
        }

        do {
            NSLog("[AppContainer] Connecting to backend at 127.0.0.1:%d", port)
            try await backendAPI.connect(host: "127.0.0.1", port: port)
            NSLog("[AppContainer] Connected successfully")
        } catch {
            NSLog("[AppContainer] Connection failed: %@", error.localizedDescription)
            self.error = error
        }
    }

    private func setupAPIObservation() {
        apiState.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
                if case .connected = state {
                    Task { [weak self] in
                        await self?.refreshRepositories()
                    }
                }
            }
            .store(in: &cancellables)
    }

    @MainActor
    private func refreshRepositories() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                try? await self?.diskTypeRepository.refresh()
            }
            group.addTask { [weak self] in
                try? await self?.mountRepository.refresh()
            }
            group.addTask { [weak self] in
                try? await self?.logRepository.refresh()
            }

            for await _ in group {}
        }
    }
}
