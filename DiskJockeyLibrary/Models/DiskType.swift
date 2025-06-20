import Foundation

/// Represents a built-in remote disk type in the system
public struct DiskType: Identifiable, Equatable, Hashable, Codable {
    // MARK: - Properties
    
    /// Unique identifier for the disk type (conforms to Identifiable)
    public var id: String { name }
    
    /// Display name of the disk type
    public let name: String
    
    /// Version of the disk type implementation
    public let version: String
    
    /// Description of what this disk type does
    public let description: String
    
    // MARK: - Initialization
    
    public init(
        name: String,
        version: String,
        description: String
    ) {
        self.name = name
        self.version = version
        self.description = description
    }
    
    // MARK: - Equatable & Hashable
    
    public static func == (lhs: DiskType, rhs: DiskType) -> Bool {
        lhs.id == rhs.id &&
        lhs.version == rhs.version
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(version)
    }
}
