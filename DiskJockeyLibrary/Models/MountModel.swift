import Foundation
import Combine

/// Represents a mount point in the mount management UI
public struct MountPoint: Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var type: MountType
    public var url: String
    public var username: String
    public var password: String
    
    // Samba-specific
    public var hostname: String?
    public var shareName: String?
    
    public init(
        id: UUID = UUID(),
        name: String = "",
        type: MountType = .webdav,
        url: String = "",
        username: String = "",
        password: String = "",
        hostname: String? = nil,
        shareName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.url = url
        self.username = username
        self.password = password
        self.hostname = hostname
        self.shareName = shareName
    }
}

/// Model for managing mount points in the UI
public class MountModel: ObservableObject {
    @Published public var mounts: [MountPoint] = []
    @Published public var selectedMount: MountPoint?
    @Published public var isAdding: Bool = false
    @Published public var newMount: MountPoint
    
    public init() {
        self.newMount = MountPoint()
    }
    
    /// Adds a new mount point
    public func addMount(_ mount: MountPoint) {
        mounts.append(mount)
    }
    
    /// Updates an existing mount point
    public func updateMount(_ mount: MountPoint) {
        if let index = mounts.firstIndex(where: { $0.id == mount.id }) {
            mounts[index] = mount
        }
    }
    
    /// Deletes a mount point
    public func deleteMount(_ mount: MountPoint) {
        mounts.removeAll { $0.id == mount.id }
    }
}
