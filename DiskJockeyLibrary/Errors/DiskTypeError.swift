import Foundation

/// Errors that can occur during diskType operations
public enum DiskTypeError: LocalizedError, Equatable {
    case diskTypeNotFound(id: String)
    case diskTypeConfigurationError(underlyingError: Error? = nil)
    case diskTypeRuntimeError(message: String)
    case diskTypeLoadFailed(underlyingError: Error? = nil)
    case diskTypePermissionDenied
    
    public var errorDescription: String? {
        switch self {
        case .diskTypeNotFound(let id):
            return "DiskType not found: \(id)"
        case .diskTypeConfigurationError(let error):
            if let error = error {
                return "Invalid diskType configuration: \(error.localizedDescription)"
            } else {
                return "Invalid diskType configuration"
            }
        case .diskTypeRuntimeError(let message):
            return message
        case .diskTypeLoadFailed(let error):
            if let error = error {
                return "Failed to load diskType: \(error.localizedDescription)"
            } else {
                return "Failed to load diskType"
            }
        case .diskTypePermissionDenied:
            return "Permission denied"
        }
    }
    
    public var recoverySuggestion: String? {
        switch self {
        case .diskTypeNotFound:
            return "Check if the diskType ID is correct."
        case .diskTypeLoadFailed, .diskTypeConfigurationError:
            return "Please try again later. If the problem persists, restart the application or contact support."
        case .diskTypeRuntimeError, .diskTypePermissionDenied:
            return "Please check your configuration and try again."
        }
    }
    
    public static func == (lhs: DiskTypeError, rhs: DiskTypeError) -> Bool {
        switch (lhs, rhs) {
        case (.diskTypeNotFound(let lhsId), .diskTypeNotFound(let rhsId)):
            return lhsId == rhsId
        case (.diskTypeConfigurationError, .diskTypeConfigurationError):
            return true
        case (.diskTypeRuntimeError(let lhsMsg), .diskTypeRuntimeError(let rhsMsg)):
            return lhsMsg == rhsMsg
        case (.diskTypeLoadFailed, .diskTypeLoadFailed):
            return true
        case (.diskTypePermissionDenied, .diskTypePermissionDenied):
            return true
        default:
            return false
        }
    }
}

// MARK: - Error Handling Utilities

extension DiskTypeError {
    /// Creates an appropriate DiskTypeError from a general Error
    static func from(error: Error) -> DiskTypeError {
        if let diskTypeError = error as? DiskTypeError {
            return diskTypeError
        } else if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                return .diskTypeRuntimeError(message: "Network error: \(error.localizedDescription)")
            case .cannotFindHost, .cannotConnectToHost:
                return .diskTypeRuntimeError(message: "Cannot connect to host: \(error.localizedDescription)")
            case .userAuthenticationRequired:
                return .diskTypePermissionDenied
            default:
                return .diskTypeRuntimeError(message: error.localizedDescription)
            }
        } else {
            return .diskTypeRuntimeError(message: error.localizedDescription)
        }
    }
}

// MARK: - DiskType State

public enum DiskTypeState: String, Codable, Equatable {
    case enabled
    case disabled
    case needsUpdate
    case error
    case loading
}
