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
            // Find the mount to get its mount_id
            guard let mountId = mounts.first(where: { $0.id == id })?.metadata["mount_id"].flatMap(UInt32.init) else {
                throw MountError.mountNotFound(id: id)
            }
            
            var request = Api_MountRequest()
            request.mountID = mountId
            
            let _: Api_MountResponse = try await api.sendRequest(
                request,
                responseType: Api_MountResponse.self,
                messageType: .mountRequest
            )
            
            // Update local state with a new mounted instance
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
            // Find the mount to get its mount_id
            guard let mountId = mounts.first(where: { $0.id == id })?.metadata["mount_id"].flatMap(UInt32.init) else {
                throw MountError.mountNotFound(id: id)
            }
            
            var request = Api_UnmountRequest()
            request.mountID = mountId
            
            let _: Api_UnmountResponse = try await api.sendRequest(
                request,
                responseType: Api_UnmountResponse.self,
                messageType: .unmountRequest
            )
            
            // Update local state with a new unmounted instance
            var updatedMount = mounts[index]
            updatedMount = updatedMount.withMounted(false)
            mounts[index] = updatedMount
        } catch {
            self.error = error
            throw error
        }
    }
    
    public func addMount(_ mount: Mount) async throws {
        var request = Api_CreateMountRequest()
        request.name = mount.name
        request.pluginType = mount.type.rawValue
        
        // Add mount configuration to the config dictionary
        var config: [String: String] = [:]
        if !mount.path.isEmpty { config["path"] = mount.path }
        if !mount.remotePath.isEmpty { config["remotePath"] = mount.remotePath }
        request.config = config
        
        let _: Api_CreateMountResponse = try await api.sendRequest(
            request,
            responseType: Api_CreateMountResponse.self,
            messageType: .createMountRequest
        )
        
        // Refresh the mounts list
        await fetchMounts()
    }
    
    public func removeMount(id: UUID) async throws {
        // Find the mount to get its mount_id
        guard let mountId = mounts.first(where: { $0.id == id })?.metadata["mount_id"].flatMap(UInt32.init) else {
            throw MountError.mountNotFound(id: id)
        }
        
        var request = Api_DeleteMountRequest()
        request.mountID = mountId
        
        let _: Api_DeleteMountResponse = try await api.sendRequest(
            request,
            responseType: Api_DeleteMountResponse.self,
            messageType: .deleteMountRequest
        )
        
        // Remove from local state if the API call succeeds
        mounts.removeAll { $0.id == id }
    }
    
    // MARK: - Private Methods
    
    private func getCachedMounts() -> [Mount] {
        // In a real app, this would load from local cache/UserDefaults
        return []
    }
}
