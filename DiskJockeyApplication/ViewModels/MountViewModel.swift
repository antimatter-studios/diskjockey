import Foundation
import Combine
import SwiftUI
import DiskJockeyLibrary

@MainActor
public class MountViewModel: ObservableObject {
    // MARK: - Properties
    
    @Published public private(set) var mounts: [Mount] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: Error?
    
    private var repository: MountRepository
    
    public init(repository: MountRepository) {
        self.repository = repository
    }
    
    // MARK: - Public Methods
    /// Loads the list of available mounts
    public func loadMounts() async {
        isLoading = true
        error = nil
        
        await repository.refresh()
        mounts = repository.mounts
        
        isLoading = false
    }
}
