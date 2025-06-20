import Foundation
import Combine
import DiskJockeyLibrary

/// Manages the list of available disk types
@MainActor
public final class DiskTypeRepository: ObservableObject {
    // MARK: - Properties
    
    private let api: BackendAPI
    
    /// The list of available diskTypes
    @Published public private(set) var diskTypes: [DiskType] = []
    
    /// The current error state, if any
    @Published public private(set) var error: Error?
    
    /// Whether a refresh operation is in progress
    @Published public private(set) var isLoading = false
    
    // MARK: - Initialization
    
    public init(api: BackendAPI) {
        self.api = api
    }
    
    // MARK: - Public Methods
    
    /// Refreshes the list of disk types from the backend
    public func refresh() async {
        isLoading = true
        error = nil
        
        do {
            diskTypes = try await api.listDiskTypes()
        } catch let error {
            self.error = error
            print("Failed to fetch diskTypes: \(error)")
        }
        
        isLoading = false
    }
}
