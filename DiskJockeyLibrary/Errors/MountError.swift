import Foundation

/// Errors that can occur during mount operations
public enum MountError: LocalizedError, Equatable {
    // MARK: - Mount Not Found
    case mountNotFound(id: UUID? = nil)
    
    // MARK: - Mount Operations
    case mountFailed(message: String? = nil)
    case unmountFailed(message: String? = nil)
    case addMountFailed(message: String? = nil)
    case removeMountFailed(message: String? = nil)
    case mountAlreadyExists(name: String)
    case invalidMountConfiguration(message: String? = nil)
    
    // MARK: - Network & Connectivity
    case networkError(Error? = nil)
    case connectionFailed(Error? = nil)
    case timeout
    
    // MARK: - File System
    case invalidPath(String? = nil)
    case insufficientPermissions
    case diskFull
    case ioError(Error? = nil)
    
    // MARK: - Resource Management
    case resourceUnavailable(resource: String? = nil)
    case resourceBusy(resource: String? = nil)
    
    // MARK: - Error Descriptions
    
    public var errorDescription: String? {
        switch self {
        case .mountNotFound(let id):
            if let id = id {
                return "Mount with ID \(id.uuidString) not found."
            } else {
                return "Mount not found."
            }
            
        case .mountFailed(let message):
            return message ?? "Failed to mount."
            
        case .unmountFailed(let message):
            return message ?? "Failed to unmount."
            
        case .addMountFailed(let message):
            return message ?? "Failed to add mount."
            
        case .removeMountFailed(let message):
            return message ?? "Failed to remove mount."
            
        case .mountAlreadyExists(let name):
            return "A mount with the name '\(name)' already exists."
            
        case .invalidMountConfiguration(let message):
            return message ?? "Invalid mount configuration."
            
        case .networkError(let error):
            if let error = error {
                return "Network error: \(error.localizedDescription)"
            } else {
                return "A network error occurred."
            }
            
        case .connectionFailed(let error):
            if let error = error {
                return "Connection failed: \(error.localizedDescription)"
            } else {
                return "Connection to the server failed."
            }
            
        case .timeout:
            return "The operation timed out."
            
        case .invalidPath(let path):
            if let path = path {
                return "Invalid path: \(path)"
            } else {
                return "Invalid path."
            }
            
        case .insufficientPermissions:
            return "Insufficient permissions to perform this operation."
            
        case .diskFull:
            return "There is not enough space on the disk."
            
        case .ioError(let error):
            if let error = error {
                return "I/O error: \(error.localizedDescription)"
            } else {
                return "An I/O error occurred."
            }
            
        case .resourceUnavailable(let resource):
            if let resource = resource {
                return "Resource not available: \(resource)."
            } else {
                return "A required resource is not available."
            }
            
        case .resourceBusy(let resource):
            if let resource = resource {
                return "Resource is busy: \(resource)."
            } else {
                return "The resource is currently in use."
            }
        }
    }
    
    public var recoverySuggestion: String? {
        switch self {
        case .mountNotFound:
            return "Check if the mount exists and try again."
            
        case .mountFailed, .unmountFailed, .addMountFailed, .removeMountFailed:
            return "Please try again. If the problem persists, check the logs for more details."
            
        case .mountAlreadyExists:
            return "Please choose a different name for the mount."
            
        case .invalidMountConfiguration:
            return "Please check the mount configuration and try again."
            
        case .networkError, .connectionFailed:
            return "Please check your network connection and try again."
            
        case .timeout:
            return "The operation took too long. Please try again."
            
        case .invalidPath:
            return "Please check the path and try again."
            
        case .insufficientPermissions:
            return "Please check your permissions and try again."
            
        case .diskFull:
            return "Free up some disk space and try again."
            
        case .ioError, .resourceUnavailable, .resourceBusy:
            return "Please try again later. If the problem persists, restart the application."
        }
    }
    
    // MARK: - Equatable
    
    public static func == (lhs: MountError, rhs: MountError) -> Bool {
        switch (lhs, rhs) {
        case (.mountNotFound(let lhsId), .mountNotFound(let rhsId)):
            return lhsId == rhsId
        case (.mountFailed(let lhsMsg), .mountFailed(let rhsMsg)):
            return lhsMsg == rhsMsg
        case (.unmountFailed(let lhsMsg), .unmountFailed(let rhsMsg)):
            return lhsMsg == rhsMsg
        case (.addMountFailed(let lhsMsg), .addMountFailed(let rhsMsg)):
            return lhsMsg == rhsMsg
        case (.removeMountFailed(let lhsMsg), .removeMountFailed(let rhsMsg)):
            return lhsMsg == rhsMsg
        case (.mountAlreadyExists(let lhsName), .mountAlreadyExists(let rhsName)):
            return lhsName == rhsName
        case (.invalidMountConfiguration(let lhsMsg), .invalidMountConfiguration(let rhsMsg)):
            return lhsMsg == rhsMsg
        case (.networkError, .networkError):
            return true
        case (.connectionFailed, .connectionFailed):
            return true
        case (.timeout, .timeout):
            return true
        case (.invalidPath(let lhsPath), .invalidPath(let rhsPath)):
            return lhsPath == rhsPath
        case (.insufficientPermissions, .insufficientPermissions):
            return true
        case (.diskFull, .diskFull):
            return true
        case (.ioError, .ioError):
            return true
        case (.resourceUnavailable(let lhsRes), .resourceUnavailable(let rhsRes)):
            return lhsRes == rhsRes
        case (.resourceBusy(let lhsRes), .resourceBusy(let rhsRes)):
            return lhsRes == rhsRes
        default:
            return false
        }
    }
}

// MARK: - Error Handling Utilities

extension MountError {
    /// Creates an appropriate MountError from a general Error
    static func from(error: Error) -> MountError {
        if let mountError = error as? MountError {
            return mountError
        } else if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                return .networkError(error)
            case .cannotFindHost, .cannotConnectToHost:
                return .connectionFailed(error)
            case .userAuthenticationRequired:
                return .insufficientPermissions
            default:
                return .networkError(error)
            }
        } else {
            return .ioError(error)
        }
    }
}
