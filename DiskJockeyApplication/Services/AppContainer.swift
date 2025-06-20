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
    
    /// Current backend process state
    @Published public private(set) var processState: BackendProcess.State = .stopped
    
    /// Current error state, if any
    @Published public private(set) var error: Error?
    
    // MARK: - Private Properties
    
    private let backendProcess: BackendProcess
    public let apiState: BackendAPIState
    public let backendAPI: BackendAPI
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    public init() {
        // Initialize state and API
        self.apiState = BackendAPIState()
        self.backendAPI = BackendAPI(state: self.apiState)
        self.connectionState = .disconnected
        self.processState = .stopped
                
        // Initialize repositories with the API
        self.diskTypeRepository = DiskTypeRepository(api: self.backendAPI)
        self.mountRepository = MountRepository(api: self.backendAPI)
        self.logRepository = LogRepository(api: self.backendAPI)
        
        // Initialize logger first (if needed)
        self.appLogModel = AppLogModel(logRepository: self.logRepository)

        // Initialize backend process
        self.backendProcess = BackendProcess(logger: self.logRepository)

        // Set reconnect handler for backendAPI
        Task { await self.backendAPI.setReconnectHandler { [weak self] in
            print("Backend disconnected, attempting to restart...")
            await self?.restartBackend()
        }}

        // Observe connection state changes from apiState
        self.apiState.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
            }
            .store(in: &cancellables)
                
        // Set up observations
        setupProcessObservation()
        setupAPIObservation()
    }
    
    // MARK: - Public Methods

    /// Ensures the backend is connected, restarting if needed, then performs the given async action.
    public func ensureBackendConnectedAndPerform(_ action: @escaping () async throws -> Void) {
        Task {
            if case .connected = self.connectionState {
                try? await action()
            } else {
                print("Backend not connected, attempting to restart...")
                await self.restartBackend()
                let connected = await waitForConnection(timeout: 10)
                if connected {
                    try? await action()
                } else {
                    self.error = NSError(domain: "AppContainer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to reconnect to backend"])
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
    
    /// Starts the backend process
    public func startBackend() {
        Task {
            do {
                try? await backendProcess.start()
            } catch {
                self.error = error
            }
        }
    }
    
    /// Stops the backend process
    public func stopBackend() {
        backendProcess.stop()
    }
    
    /// Restarts the backend process
    public func restartBackend() {
        Task {
            do {
                try await backendProcess.restart()
            } catch {
                self.error = error
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func setupProcessObservation() {
        backendProcess.processStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                self.processState = state
                
                switch state {
                case .running(let info):
                    self.handleBackendStarted(port: Int(info.port))
                case .stopped:
                    self.handleBackendStopped()
                case .failed(let error):
                    self.handleBackendFailed(error)
                case .starting:
                    // Just update the state, no additional handling needed
                    break
                }
            }
            .store(in: &cancellables)
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
    
    private func handleBackendStarted(port: Int) {
        error = nil
        // Connect the API to the backend
        Task {
            do {
                print("Connecting to backend at localhost:\(port)")
                try await backendAPI.connect(host: "localhost", port: port)
            } catch {
                self.error = error
            }
        }
    }
    
    private func handleBackendStopped() {
        Task {
            await backendAPI.disconnect()
        }
        error = nil
    }
    
    private func handleBackendFailed(_ error: BackendProcessError) {
        self.error = error
    }
    
    @MainActor
    private func refreshRepositories() async {
        // Refresh all repositories when the backend connects
        // Use TaskGroup to refresh all repositories concurrently
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
            
            // Wait for all refreshes to complete
            for await _ in group {}
        }
    }
}
