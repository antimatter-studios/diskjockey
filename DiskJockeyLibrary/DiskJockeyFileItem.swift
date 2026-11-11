import Foundation

// DiskJockeyFileItem: Swift-native abstraction for a file or directory
public struct DiskJockeyFileItem {
    public let name: String
    public let size: Int64
    public let isDirectory: Bool
    /// The remote's last modification time in whole seconds since the
    /// Unix epoch, as the backend reported it, or nil when the caller
    /// has no stat record (a synthetic root, a just-written upload).
    public let modificationTime: Int64?
    /// The remote's permission bits, or nil when unknown.
    public let mode: UInt32?

    public init(name: String, size: Int64, isDirectory: Bool,
                modificationTime: Int64? = nil, mode: UInt32? = nil) {
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.modificationTime = modificationTime
        self.mode = mode
    }
}
