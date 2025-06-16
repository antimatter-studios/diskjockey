import Foundation
import Combine
import DiskJockeyLibrary

@MainActor
public final class AppContainer: ObservableObject {
    // MARK: - Public Properties
    
    /// The plugin repository for managing plugins
    public let pluginRepository: PluginRepository
    
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
    private var backendAPI: BackendAPI
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    public init() {
        // Initialize backend process
        self.backendProcess = BackendProcess()
        
        // Initialize API
        self.backendAPI = BackendAPI()
        
        // Initialize repositories with the API
        self.pluginRepository = PluginRepository(api: self.backendAPI)
        self.mountRepository = MountRepository(api: self.backendAPI)
        self.logRepository = LogRepository(api: self.backendAPI)
        
        // Set up observations
        setupProcessObservation()
        setupAPIObservation()
    }
    
    // MARK: - Public Methods
    
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
        backendProcess.statePublisher
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
        backendAPI.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
            }
            .store(in: &cancellables)
    }
    
    private func handleBackendStarted(port: Int) {
        error = nil
        
        // Connect the API to the backend
        Task {
            do {
                try await backendAPI.connect(host: "localhost", port: port)
                await refreshRepositories()
            } catch {
                self.error = error
            }
        }
    }
    
    private func handleBackendStopped() {
        // The API will automatically disconnect when the process terminates
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
                try? await self?.pluginRepository.refresh()
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
