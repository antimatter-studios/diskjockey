import Foundation

/// Represents a single log entry in the system
public struct LogEntry: Identifiable, Equatable, Hashable, Codable {
    /// Unique identifier for the log entry
    public let id: UUID
    
    /// The log message
    public let message: String
    
    /// The log category (e.g., "backend", "app", "sync")
    public let category: String
    
    /// The timestamp when the log was created
    public let timestamp: Date
    
    /// The source of the log (e.g., "Backend", "App", "FileProvider")
    public let source: String
    
    /// Additional structured data associated with the log entry
    public let metadata: [String: String]?
    
    /// Creates a new log entry
    public init(
        id: UUID = UUID(),
        message: String,
        category: String,
        timestamp: Date = Date(),
        source: String = "App",
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.message = message
        self.category = category
        self.timestamp = timestamp
        self.source = source
        self.metadata = metadata
    }
    
    // MARK: - Equatable & Hashable
    
    public static func == (lhs: LogEntry, rhs: LogEntry) -> Bool {
        lhs.id == rhs.id &&
        lhs.timestamp == rhs.timestamp &&
        lhs.message == rhs.message
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(timestamp)
        hasher.combine(message)
    }
}
