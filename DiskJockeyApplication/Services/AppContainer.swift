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

    /// Tails NDJSON log files written by subprocesses (FSKit extensions,
    /// backends) and pushes entries into `logRepository` so they render
    /// in the UI Logs panel.
    private var logTailService: LogTailService?

    /// Enumerates system-mounted disks (ext4 etc) so the sidebar can show
    /// them for visibility. Read-only — not user-configurable.
    public let attachedDisks: AttachedDisksModel = AttachedDisksModel()

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

        // Populate the sidebar BEFORE we start replaying ndjson events.
        // Ordering matters: on launch the tail reads existing lines from
        // each ndjson file; if the disk model hasn't polled mount(8) yet
        // those events would match no disk and get dropped.
        // (The model ALSO buffers unmatched events by BSD so events for
        // not-yet-polled disks are replayed once they appear — belt and
        // braces.)
        self.attachedDisks.start()

        // Tail subprocess NDJSON log files. Lines flow into the central
        // logRepository; kind-tagged events (volume.clean/dirty,
        // volume.info, fsck.start/progress/done/failed) plus generic
        // per-bsd log lines also route to AttachedDisksModel so the
        // per-disk detail pane shows live status, identity, and a
        // partition-scoped log.
        let tail = LogTailService(logRepository: self.logRepository)
        let disks = self.attachedDisks
        tail.onEvent = { kind, fields in
            disks.applyExtensionEvent(kind: kind, fields: fields)
        }
        tail.onLine = { line in
            disks.applyLogLine(line)
        }
        tail.start()
        self.logTailService = tail
        AppLog.shared.info("DiskJockey launched — log tail started")

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

        let maxAttempts = 5
        for attempt in 1...maxAttempts {
            NSLog("[AppContainer] connectToBackend attempt %d/%d", attempt, maxAttempts)

            guard let port = await serviceManager.discoverPort() else {
                NSLog("[AppContainer] Could not discover backend port (attempt %d)", attempt)
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                self.error = NSError(domain: "AppContainer", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Could not discover backend port. Is the backend running?"
                ])
                return
            }

            do {
                NSLog("[AppContainer] Connecting to backend at 127.0.0.1:%d", port)
                try await backendAPI.connect(host: "127.0.0.1", port: port)
                NSLog("[AppContainer] Connected successfully")
                return
            } catch {
                NSLog("[AppContainer] Connection failed (attempt %d): %@", attempt, error.localizedDescription)
                if attempt == maxAttempts {
                    self.error = error
                } else {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
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
