import Foundation
import FileProvider
import DiskJockeyLibrary

/// MountManager is responsible for mounting and unmounting File Provider domains for each mount.
@MainActor
final class MountManager: ObservableObject {
    static let shared = MountManager()
    
    /// Keeps track of active domains by mount ID
    @Published private(set) var activeDomains: [UUID: NSFileProviderDomain] = [:]
    
    /// Mounts a file provider domain for the given mount
    func mount(_ mount: Mount) async throws {
        let domainIdentifier = NSFileProviderDomainIdentifier(mount.id.uuidString)
        let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: mount.name)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.add(domain) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    Task { @MainActor in
                        self.activeDomains[mount.id] = domain
                        continuation.resume(returning: ())
                    }
                }
            }
        }
    }
    
    /// Unmounts the file provider domain for the given mount
    func unmount(_ mount: Mount) async throws {
        guard let domain = activeDomains[mount.id] else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.remove(domain) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    Task { @MainActor in
                        self.activeDomains.removeValue(forKey: mount.id)
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    /// Checks if the mount is currently mounted (domain registered)
    func isMounted(_ mount: Mount) -> Bool {
        activeDomains[mount.id] != nil
    }
}
