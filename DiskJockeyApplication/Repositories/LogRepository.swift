import Foundation
import Combine
import DiskJockeyLibrary

/// Repository for managing log entries
@MainActor
public final class LogRepository: ObservableObject {
    // MARK: - Published Properties
    
    @Published public private(set) var logs: [LogEntry] = []
    @Published public private(set) var error: Error?
    @Published public private(set) var isLoading = false
    
    // MARK: - Private Properties
    
    private let maxLogEntries = 1000
    private let api: BackendAPI
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    public init(api: BackendAPI) {
        self.api = api
        // Load initial logs
        Task {
            await fetchLogs()
        }
    }
    
    // MARK: - Public Methods
    
    public func addLogEntry(_ entry: LogEntry) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.logs.insert(entry, at: 0)
            
            // Trim logs if they exceed the maximum count
            if self.logs.count > self.maxLogEntries {
                self.logs = Array(self.logs.prefix(self.maxLogEntries))
            }
        }
    }
    
    public func fetchLogs(limit: Int = 100, filter: String? = nil) async {
        await refresh(limit: limit, filter: filter)
    }
    
    public func refresh() async {
        await refresh(limit: 100, filter: nil)
    }
    
    /// Internal refresh implementation with parameters
    private func refresh(limit: Int, filter: String?) async {
        guard !isLoading else { return }
        
        isLoading = true
        error = nil
        
        // For now, we'll just use the in-memory logs
        // In the future, we can implement actual API calls when the backend supports it
        var filteredLogs = logs
        
        // Apply filter if provided
        if let filter = filter, !filter.isEmpty {
            let lowercasedFilter = filter.lowercased()
            filteredLogs = filteredLogs.filter {
                $0.message.lowercased().contains(lowercasedFilter) ||
                $0.source.lowercased().contains(lowercasedFilter) ||
                $0.level.rawValue.lowercased().contains(lowercasedFilter)
            }
        }
        
        // Apply limit
        let limitedLogs = Array(filteredLogs.prefix(limit))
        
        // Update on main thread
        await MainActor.run {
            self.logs = limitedLogs
            self.isLoading = false
        }
    }
    
    public func clearLogs() async throws {
        await MainActor.run {
            self.logs = []
        }
    }
    
    // MARK: - Private Methods
    
    private func getCachedLogs() -> [LogEntry] {
        // In a real app, this would load from local cache/UserDefaults
        return []
    }
}
