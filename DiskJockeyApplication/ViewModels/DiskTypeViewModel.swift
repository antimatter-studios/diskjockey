import Foundation
import Combine
import SwiftUI
import DiskJockeyLibrary

@MainActor
public class DiskTypeViewModel: ObservableObject {
    // MARK: - Properties
    
    @Published public private(set) var diskTypes: [DiskType] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: Error?
    
    private var repository: DiskTypeRepository
    
    init (
        repository: DiskTypeRepository
    ) {
        self.repository = repository
    }
        
    // MARK: - Public Methods
    
    /// Loads the list of available disk types
    public func loadDiskTypes() async {
        isLoading = true
        error = nil
        
        await repository.refresh()
        diskTypes = repository.diskTypes
        
        isLoading = false
    }
}
