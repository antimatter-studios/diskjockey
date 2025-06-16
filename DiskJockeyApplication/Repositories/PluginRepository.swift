import Foundation
import Combine
import DiskJockeyLibrary

/// Manages the list of available plugins
@MainActor
public final class PluginRepository: ObservableObject {
    // MARK: - Properties
    
    private let api: BackendAPI
    
    /// The list of available plugins
    @Published public private(set) var plugins: [Plugin] = []
    
    /// The current error state, if any
    @Published public private(set) var error: Error?
    
    /// Whether a refresh operation is in progress
    @Published public private(set) var isLoading = false
    
    // MARK: - Initialization
    
    public init(api: BackendAPI) {
        self.api = api
    }
    
    // MARK: - Public Methods
    
    /// Refreshes the list of plugins from the backend
    public func refresh() async {
        isLoading = true
        error = nil
        
        do {
            plugins = try await api.listPlugins()
        } catch let error {
            self.error = error
            print("Failed to fetch plugins: \(error)")
        }
        
        isLoading = false
    }
}

