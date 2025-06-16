import Foundation
import Combine
import SwiftUI
import DiskJockeyLibrary

@MainActor
public class PluginViewModel: ObservableObject {
    // MARK: - Properties
    
    @Published public private(set) var plugins: [Plugin] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: Error?
    
    private var repository: PluginRepository
    
    init (
        repository: PluginRepository
    ) {
        self.repository = repository
    }
        
    // MARK: - Public Methods
    
    /// Loads the list of available plugins
    public func loadPlugins() async {
        isLoading = true
        error = nil
        
        await repository.refresh()
        plugins = repository.plugins
        
        isLoading = false
    }
}
