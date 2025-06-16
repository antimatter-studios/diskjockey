import Foundation

/// Errors that can occur during plugin operations
public enum PluginError: LocalizedError, Equatable {
    case pluginNotFound(id: String)
    case pluginConfigurationError(underlyingError: Error? = nil)
    case pluginRuntimeError(message: String)
    case pluginLoadFailed(underlyingError: Error? = nil)
    case pluginPermissionDenied
    
    public var errorDescription: String? {
        switch self {
        case .pluginNotFound(let id):
            return "Plugin not found: \(id)"
        case .pluginConfigurationError(let error):
            if let error = error {
                return "Invalid plugin configuration: \(error.localizedDescription)"
            } else {
                return "Invalid plugin configuration"
            }
        case .pluginRuntimeError(let message):
            return message
        case .pluginLoadFailed(let error):
            if let error = error {
                return "Failed to load plugin: \(error.localizedDescription)"
            } else {
                return "Failed to load plugin"
            }
        case .pluginPermissionDenied:
            return "Permission denied"
        }
    }
    
    public var recoverySuggestion: String? {
        switch self {
        case .pluginNotFound:
            return "Check if the plugin ID is correct."
        case .pluginLoadFailed, .pluginConfigurationError:
            return "Please try again later. If the problem persists, restart the application or contact support."
        case .pluginRuntimeError, .pluginPermissionDenied:
            return "Please check your configuration and try again."
        }
    }
    
    public static func == (lhs: PluginError, rhs: PluginError) -> Bool {
        switch (lhs, rhs) {
        case (.pluginNotFound(let lhsId), .pluginNotFound(let rhsId)):
            return lhsId == rhsId
        case (.pluginConfigurationError, .pluginConfigurationError):
            return true
        case (.pluginRuntimeError(let lhsMsg), .pluginRuntimeError(let rhsMsg)):
            return lhsMsg == rhsMsg
        case (.pluginLoadFailed, .pluginLoadFailed):
            return true
        case (.pluginPermissionDenied, .pluginPermissionDenied):
            return true
        default:
            return false
        }
    }
}

// MARK: - Error Handling Utilities

extension PluginError {
    /// Creates an appropriate PluginError from a general Error
    static func from(error: Error) -> PluginError {
        if let pluginError = error as? PluginError {
            return pluginError
        } else if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                return .pluginRuntimeError(message: "Network error: \(error.localizedDescription)")
            case .cannotFindHost, .cannotConnectToHost:
                return .pluginRuntimeError(message: "Cannot connect to host: \(error.localizedDescription)")
            case .userAuthenticationRequired:
                return .pluginPermissionDenied
            default:
                return .pluginRuntimeError(message: error.localizedDescription)
            }
        } else {
            return .pluginRuntimeError(message: error.localizedDescription)
        }
    }
}

// MARK: - Plugin State

public enum PluginState: String, Codable, Equatable {
    case enabled
    case disabled
    case needsUpdate
    case error
    case loading
}
