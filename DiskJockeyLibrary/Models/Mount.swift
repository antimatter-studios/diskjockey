import Foundation

/// Represents a mount point in the system
public struct Mount: Identifiable, Equatable {
    /// Unique identifier for the mount
    public let id: UUID
    
    /// Type of the mount (e.g., SMB, NFS, WebDAV)
    public let diskType: DiskTypeEnum
    
    /// User-friendly name for the mount
    public let name: String
    
    /// Local filesystem path where the mount is attached
    public let path: String
    
    /// Remote path or connection string for the mount
    public let remotePath: String
    
    /// Whether the mount is currently active
    public let isMounted: Bool
    
    /// Date when the mount was last accessed
    public let lastAccessed: Date?
    
    /// Additional metadata for the mount
    public let metadata: [String: String]
    
    public init(
        id: UUID = UUID(),
        diskType: DiskTypeEnum,
        name: String,
        path: String,
        remotePath: String,
        isMounted: Bool = false,
        lastAccessed: Date? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.diskType = diskType
        self.name = name
        self.path = path
        self.remotePath = remotePath
        self.isMounted = isMounted
        self.lastAccessed = lastAccessed
        self.metadata = metadata
    }
    
    /// Returns a new Mount instance with the specified mount state
    public func withMounted(_ isMounted: Bool) -> Mount {
        Mount(
            id: self.id,
            diskType: self.diskType,
            name: self.name,
            path: self.path,
            remotePath: self.remotePath,
            isMounted: isMounted,
            lastAccessed: self.lastAccessed,
            metadata: self.metadata
        )
    }
    
    // MARK: - Equatable & Hashable
    
    public static func == (lhs: Mount, rhs: Mount) -> Bool {
        return lhs.id == rhs.id &&
               lhs.name == rhs.name &&
               lhs.path == rhs.path &&
               lhs.remotePath == rhs.remotePath &&
               lhs.isMounted == rhs.isMounted &&
               lhs.diskType == rhs.diskType &&
               lhs.lastAccessed == rhs.lastAccessed
        // Note: We're not including metadata in the equality check to maintain consistency with hash(into:)
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(path)
        hasher.combine(remotePath)
        hasher.combine(isMounted)
        hasher.combine(diskType)
        hasher.combine(lastAccessed)
        // Note: We're not including metadata in the hash to maintain consistency with Equatable
    }
}

/// Types of mount points supported by the system
