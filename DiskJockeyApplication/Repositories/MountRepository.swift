import Foundation
import Combine
import DiskJockeyLibrary

/// Repository for managing mounts
@MainActor
public final class MountRepository: ObservableObject {
    // MARK: - Published Properties
    
    @Published public private(set) var mounts: [Mount] = []
    @Published public private(set) var error: Error?
    @Published public private(set) var isLoading = false
    
    // MARK: - Private Properties
    
    private let api: BackendAPI
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    public init(api: BackendAPI) {
        self.api = api
    }
    
    /// Fetches the latest list of mounts from the backend
    public func fetchMounts() async {
        await refresh()
    }
    
    /// Refreshes the repository data
    public func refresh() async {
        guard !isLoading else { return }
        
        isLoading = true
        error = nil
        
        do {
            self.mounts = try await api.listMounts()
        } catch {
            self.error = error
            // Fall back to cached data if available
            if mounts.isEmpty {
                self.mounts = getCachedMounts()
            }
        }
        
        isLoading = false
    }
    
    public func mount(id: UUID) async throws {
        guard let index = mounts.firstIndex(where: { $0.id == id }) else {
            throw MountError.mountNotFound(id: id)
        }
        
        let mount = mounts[index]
        guard !mount.isMounted else { return }
        
        do {
            guard let mountId = mounts.first(where: { $0.id == id })?.metadata["mount_id"].flatMap(UInt32.init) else {
                throw MountError.mountNotFound(id: id)
            }
            try await api.mount(id: mountId)
            var updatedMount = mounts[index]
            updatedMount = updatedMount.withMounted(true)
            mounts[index] = updatedMount
        } catch {
            self.error = error
            throw error
        }
    }
    
    public func unmount(id: UUID) async throws {
        guard let index = mounts.firstIndex(where: { $0.id == id }) else {
            throw MountError.mountNotFound(id: id)
        }
        
        let mount = mounts[index]
        guard mount.isMounted else { return }
        
        do {
            guard let mountId = mounts.first(where: { $0.id == id })?.metadata["mount_id"].flatMap(UInt32.init) else {
                throw MountError.mountNotFound(id: id)
            }
            try await api.unmount(id: mountId)
            var updatedMount = mounts[index]
            updatedMount = updatedMount.withMounted(false)
            mounts[index] = updatedMount
        } catch {
            self.error = error
            throw error
        }
    }
    
    public func addMount(_ mount: Mount) async throws {
        try await api.addMount(mount)
        await fetchMounts()
    }
    
    public func removeMount(id: UUID) async throws {
        guard let mountId = mounts.first(where: { $0.id == id })?.metadata["mount_id"].flatMap(UInt32.init) else {
            throw MountError.mountNotFound(id: id)
        }
        try await api.removeMount(id: mountId)
        mounts.removeAll { $0.id == id }
    }
    
    // MARK: - Private Methods
    
    private func getCachedMounts() -> [Mount] {
        // In a real app, this would load from local cache/UserDefaults
        return []
    }
}
