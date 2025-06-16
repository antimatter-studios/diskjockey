import Foundation

/// A type that represents an error that can occur in the shared DiskJockey library.
/// This should only include errors that are relevant to both the main app and the File Provider extension.
public enum DiskJockeyError: LocalizedError, Equatable {
    // MARK: - File System Errors
    case fileNotFound(String)
    case permissionDenied
    case invalidFileFormat
    case fileTooLarge
    case diskFull
    case fileOperationFailed(Error)
    
    // MARK: - Network Errors (only those relevant to both targets)
    case networkUnreachable
    case connectionFailed(Error?)
    case invalidResponse
    case invalidURL
    
    // MARK: - Data Errors
    case invalidData
    case decodingFailed(Error)
    case encodingFailed(Error)
    case dataCorrupted
    
    // MARK: - Authentication & Authorization
    case authenticationRequired
    case invalidCredentials
    case sessionExpired
    case insufficientPermissions
    
    // MARK: - Generic Errors
    case unknown(Error?)
    case notImplemented
    case operationCancelled
    case timeout
    
    // MARK: - Error Descriptions
    
    public var errorDescription: String? {
        switch self {
        // File System Errors
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .permissionDenied:
            return "You don't have permission to access this resource."
        case .invalidFileFormat:
            return "The file format is not supported."
        case .fileTooLarge:
            return "The file is too large to process."
        case .diskFull:
            return "There is not enough space on the disk."
        case .fileOperationFailed(let error):
            return "File operation failed: \(error.localizedDescription)"
            
        // Network Errors
        case .networkUnreachable:
            return "The network is unreachable."
        case .connectionFailed(let error):
            if let error = error {
                return "Connection failed: \(error.localizedDescription)"
            } else {
                return "Connection failed."
            }
        case .invalidResponse:
            return "Received an invalid response."
        case .invalidURL:
            return "The provided URL is invalid."
            
        // Data Errors
        case .invalidData:
            return "The data is invalid."
        case .decodingFailed(let error):
            return "Failed to decode data: \(error.localizedDescription)"
        case .encodingFailed(let error):
            return "Failed to encode data: \(error.localizedDescription)"
        case .dataCorrupted:
            return "The data is corrupted."
            
        // Authentication & Authorization
        case .authenticationRequired:
            return "Authentication is required."
        case .invalidCredentials:
            return "Invalid credentials."
        case .sessionExpired:
            return "Your session has expired. Please log in again."
        case .insufficientPermissions:
            return "You don't have sufficient permissions to perform this action."
            
        // Generic Errors
        case .unknown(let error):
            if let error = error {
                return "An unknown error occurred: \(error.localizedDescription)"
            } else {
                return "An unknown error occurred."
            }
        case .notImplemented:
            return "This feature is not implemented yet."
        case .operationCancelled:
            return "The operation was cancelled."
        case .timeout:
            return "The operation timed out."
        }
    }
    
    // MARK: - Equatable
    
    public static func == (lhs: DiskJockeyError, rhs: DiskJockeyError) -> Bool {
        switch (lhs, rhs) {
        // File System Errors
        case (.fileNotFound(let lhsPath), .fileNotFound(let rhsPath)):
            return lhsPath == rhsPath
        case (.permissionDenied, .permissionDenied):
            return true
        case (.invalidFileFormat, .invalidFileFormat):
            return true
        case (.fileTooLarge, .fileTooLarge):
            return true
        case (.diskFull, .diskFull):
            return true
        case (.fileOperationFailed, .fileOperationFailed):
            // Consider all file operation errors equal for simplicity
            return true
            
        // Network Errors
        case (.networkUnreachable, .networkUnreachable):
            return true
        case (.connectionFailed, .connectionFailed):
            // Consider all connection failures equal
            return true
        case (.invalidResponse, .invalidResponse):
            return true
        case (.invalidURL, .invalidURL):
            return true
            
        // Data Errors
        case (.invalidData, .invalidData):
            return true
        case (.decodingFailed, .decodingFailed):
            // Consider all decoding errors equal
            return true
        case (.encodingFailed, .encodingFailed):
            // Consider all encoding errors equal
            return true
        case (.dataCorrupted, .dataCorrupted):
            return true
            
        // Authentication & Authorization
        case (.authenticationRequired, .authenticationRequired):
            return true
        case (.invalidCredentials, .invalidCredentials):
            return true
        case (.sessionExpired, .sessionExpired):
            return true
        case (.insufficientPermissions, .insufficientPermissions):
            return true
            
        // Generic Errors
        case (.unknown, .unknown):
            // Consider all unknown errors equal
            return true
        case (.notImplemented, .notImplemented):
            return true
        case (.operationCancelled, .operationCancelled):
            return true
        case (.timeout, .timeout):
            return true
            
        default:
            return false
        }
    }
    
    // MARK: - Initialization
    
    /// Creates a DiskJockeyError from a general Error
    public init(_ error: Error) {
        if let diskJockeyError = error as? DiskJockeyError {
            self = diskJockeyError
        } else {
            // Map common error types
            let nsError = error as NSError
            
            // Check error domain and code separately for better matching
            let domain = nsError.domain
            let code = nsError.code
            
            if domain == NSCocoaErrorDomain {
                switch code {
                case NSFileNoSuchFileError:
                    self = .fileNotFound(nsError.userInfo[NSFilePathErrorKey] as? String ?? "Unknown file")
                case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                    self = .permissionDenied
                case NSFileWriteOutOfSpaceError, 640: // NSFileWriteOutOfSpaceError
                    self = .diskFull
                default:
                    self = .unknown(error)
                }
            } else if domain == NSURLErrorDomain {
                switch code {
                case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost:
                    self = .networkUnreachable
                case NSURLErrorTimedOut:
                    self = .timeout
                case NSURLErrorCancelled:
                    self = .operationCancelled
                default:
                    self = .unknown(error)
                }
            } else {
                self = .unknown(error)
            }
        }
    }
}
