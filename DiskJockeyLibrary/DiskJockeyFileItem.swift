import Foundation

// DiskJockeyFileItem: Swift-native abstraction for a file or directory
public struct DiskJockeyFileItem {
    public let name: String
    public let size: Int64
    public let isDirectory: Bool
    
    public init(name: String, size: Int64, isDirectory: Bool) {
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
    }
}
