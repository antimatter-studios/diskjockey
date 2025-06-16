import Foundation

/// Represents a mount point in the system
public struct Mount: Identifiable, Equatable {
    /// Unique identifier for the mount
    public let id: UUID
    
    /// User-friendly name for the mount
    public let name: String
    
    /// Local filesystem path where the mount is attached
    public let path: String
    
    /// Remote path or connection string for the mount
    public let remotePath: String
    
    /// Whether the mount is currently active
    public let isMounted: Bool
    
    /// Type of the mount (e.g., SMB, NFS, WebDAV)
    public let type: MountType
    
    /// Date when the mount was last accessed
    public let lastAccessed: Date?
    
    /// Additional metadata for the mount
    public let metadata: [String: String]
    
    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        remotePath: String,
        isMounted: Bool = false,
        type: MountType = .other,
        lastAccessed: Date? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.remotePath = remotePath
        self.isMounted = isMounted
        self.type = type
        self.lastAccessed = lastAccessed
        self.metadata = metadata
    }
    
    /// Returns a new Mount instance with the specified mount state
    public func withMounted(_ isMounted: Bool) -> Mount {
        Mount(
            id: self.id,
            name: self.name,
            path: self.path,
            remotePath: self.remotePath,
            isMounted: isMounted,
            type: self.type,
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
               lhs.type == rhs.type &&
               lhs.lastAccessed == rhs.lastAccessed
        // Note: We're not including metadata in the equality check to maintain consistency with hash(into:)
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(path)
        hasher.combine(remotePath)
        hasher.combine(isMounted)
        hasher.combine(type)
        hasher.combine(lastAccessed)
        // Note: We're not including metadata in the hash to maintain consistency with Equatable
    }
}

/// Types of mount points supported by the system
public enum MountType: String, Codable {
    // Network protocols
    case smb = "SMB"
    case nfs = "NFS"
    case webdav = "WebDAV"
    case sftp = "SFTP"
    case ftp = "FTP"
    
    // Cloud storage
    case s3 = "S3"
    case gcs = "GCS"
    case azure = "Azure"
    
    // Local and other
    case local = "Local"
    case samba = "Samba"
    case other = "Other"
    
    public var displayName: String {
        switch self {
        case .smb: return "SMB/CIFS"
        case .nfs: return "NFS"
        case .webdav: return "WebDAV"
        case .sftp: return "SFTP"
        case .ftp: return "FTP"
        case .s3: return "Amazon S3"
        case .gcs: return "Google Cloud Storage"
        case .azure: return "Azure Blob Storage"
        case .local: return "Local Folder"
        case .samba: return "Samba"
        case .other: return "Other"
        }
    }
    
    public var systemImage: String {
        switch self {
        case .smb, .samba: return "network"
        case .nfs: return "network"
        case .webdav: return "globe"
        case .sftp: return "network"
        case .ftp: return "network"
        case .s3, .gcs, .azure: return "cloud"
        case .local: return "folder"
        case .other: return "externaldrive"
        }
    }
    
    /// Returns whether this mount type represents a cloud storage service
    public var isCloudStorage: Bool {
        [.s3, .gcs, .azure].contains(self)
    }
    
    /// Returns whether this mount type represents a network filesystem
    public var isNetworkFilesystem: Bool {
        [.smb, .nfs, .samba].contains(self)
    }
    
    /// Returns whether this mount type represents a web-based protocol
    public var isWebProtocol: Bool {
        [.webdav, .s3, .gcs, .azure].contains(self)
    }
}
