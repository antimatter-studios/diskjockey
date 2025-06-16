import Foundation

/// Represents the severity level of a log entry
public enum LogLevel: String, Codable, CaseIterable, Equatable, Hashable, Identifiable {
    public var id: String { self.rawValue }
    case all = "all"
    case debug = "debug"
    case info = "info"
    case warning = "warning"
    case error = "error"
    case critical = "critical"
    case fatal = "fatal"
    
    public var displayName: String {
        switch self {
        case .all: return "All"
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        case .critical: return "Critical"
        case .fatal: return "Fatal"
        }
    }
    
    public var iconName: String {
        switch self {
        case .all: return "ladybug"
        case .debug: return "ladybug"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.circle"
        case .critical: return "exclamationmark.octagon"
        case .fatal: return "exclamationmark.octagon"
        }
    }
    
    public var colorName: String {
        switch self {
        case .all: return "gray"
        case .debug: return "gray"
        case .info: return "blue"
        case .warning: return "yellow"
        case .error: return "red"
        case .critical: return "purple"
        case .fatal: return "purple"
        }
    }
}

/// Represents a single log entry in the system
public struct LogEntry: Identifiable, Equatable, Hashable, Codable {
    /// Unique identifier for the log entry
    public let id: UUID
    
    /// The log message
    public let message: String
    
    /// The log level
    public let level: LogLevel
    
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
        level: LogLevel = .info,
        timestamp: Date = Date(),
        source: String = "App",
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.message = message
        self.level = level
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
