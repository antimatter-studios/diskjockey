import Foundation

/// A type that represents an error that can occur in the application.
public enum AppError: LocalizedError, Equatable {
    // MARK: - Network Errors
    case networkError(Error)
    case invalidURL
    case requestFailed(Error)
    case invalidResponse
    case unauthorized
    case forbidden
    case notFound
    case serverError(String)
    
    // MARK: - Backend Errors
    case backendNotRunning
    case backendStartupFailed(Error)
    case backendConnectionFailed(Error)
    case backendTimeout
    case backendProcessTerminated
    
    // MARK: - File System Errors
    case fileNotFound(String)
    case permissionDenied
    case invalidFileFormat
    case fileTooLarge
    case diskFull
    
    // MARK: - Data Errors
    case invalidData
    case decodingFailed(Error)
    case encodingFailed(Error)
    case dataCorrupted
    case invalidInput(String)
    
    // MARK: - Authentication & Authorization
    case authenticationRequired
    case invalidCredentials
    case sessionExpired
    case insufficientPermissions
    
    // MARK: - Plugin Errors
    case pluginNotFound
    case pluginLoadFailed(String)
    case pluginExecutionFailed(String)
    case pluginIncompatible
    
    // MARK: - Mount Errors
    case mountFailed(String)
    case unmountFailed(String)
    case mountPointInUse
    case mountPointInvalid
    
    // MARK: - Generic Errors
    case unknown(Error?)
    case notImplemented
    case unexpectedState
    case operationCancelled
    case rateLimitExceeded
    case timeout
    
    // MARK: - Error Descriptions
    
    public var errorDescription: String? {
        switch self {
        // Network Errors
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidURL:
            return "The provided URL is invalid."
        case .requestFailed(let error):
            return "Request failed: \(error.localizedDescription)"
        case .invalidResponse:
            return "Received an invalid response from the server."
        case .unauthorized:
            return "You are not authorized to perform this action."
        case .forbidden:
            return "You don't have permission to access this resource."
        case .notFound:
            return "The requested resource was not found."
        case .serverError(let message):
            return "Server error: \(message)"
            
        // Backend Errors
        case .backendNotRunning:
            return "The backend service is not running."
        case .backendStartupFailed(let error):
            return "Failed to start backend service: \(error.localizedDescription)"
        case .backendConnectionFailed(let error):
            return "Failed to connect to backend: \(error.localizedDescription)"
        case .backendTimeout:
            return "The backend service did not respond in time."
        case .backendProcessTerminated:
            return "The backend process terminated unexpectedly."
            
        // File System Errors
        case .fileNotFound(let path):
            return "File not found at path: \(path)"
        case .permissionDenied:
            return "You don't have permission to access this file or directory."
        case .invalidFileFormat:
            return "The file format is not supported."
        case .fileTooLarge:
            return "The file is too large to be processed."
        case .diskFull:
            return "There is not enough space on the disk."
            
        // Data Errors
        case .invalidData:
            return "The data is invalid or corrupted."
        case .decodingFailed(let error):
            return "Failed to decode data: \(error.localizedDescription)"
        case .encodingFailed(let error):
            return "Failed to encode data: \(error.localizedDescription)"
        case .dataCorrupted:
            return "The data is corrupted and cannot be read."
        case .invalidInput(let message):
            return "Invalid input: \(message)"
            
        // Authentication & Authorization
        case .authenticationRequired:
            return "Authentication is required to perform this action."
        case .invalidCredentials:
            return "Invalid username or password."
        case .sessionExpired:
            return "Your session has expired. Please log in again."
        case .insufficientPermissions:
            return "You don't have sufficient permissions to perform this action."
            
        // Plugin Errors
        case .pluginNotFound:
            return "The requested plugin was not found."
        case .pluginLoadFailed(let message):
            return "Failed to load plugin: \(message)"
        case .pluginExecutionFailed(let message):
            return "Plugin execution failed: \(message)"
        case .pluginIncompatible:
            return "The plugin is not compatible with this version of the application."
            
        // Mount Errors
        case .mountFailed(let message):
            return "Failed to mount: \(message)"
        case .unmountFailed(let message):
            return "Failed to unmount: \(message)"
        case .mountPointInUse:
            return "The mount point is already in use."
        case .mountPointInvalid:
            return "The mount point is invalid or inaccessible."
            
        // Generic Errors
        case .unknown(let error):
            if let error = error {
                return "An unknown error occurred: \(error.localizedDescription)"
            } else {
                return "An unknown error occurred."
            }
        case .notImplemented:
            return "This feature is not implemented yet."
        case .unexpectedState:
            return "The application is in an unexpected state."
        case .operationCancelled:
            return "The operation was cancelled."
        case .rateLimitExceeded:
            return "Rate limit exceeded. Please try again later."
        case .timeout:
            return "The operation timed out."
        }
    }
    
    // MARK: - Equatable
    
    public static func == (lhs: AppError, rhs: AppError) -> Bool {
        switch (lhs, rhs) {
        case (.networkError, .networkError),
             (.invalidURL, .invalidURL),
             (.requestFailed, .requestFailed),
             (.invalidResponse, .invalidResponse),
             (.unauthorized, .unauthorized),
             (.forbidden, .forbidden),
             (.notFound, .notFound),
             (.serverError, .serverError),
             (.backendNotRunning, .backendNotRunning),
             (.backendStartupFailed, .backendStartupFailed),
             (.backendConnectionFailed, .backendConnectionFailed),
             (.backendTimeout, .backendTimeout),
             (.backendProcessTerminated, .backendProcessTerminated),
             (.fileNotFound, .fileNotFound),
             (.permissionDenied, .permissionDenied),
             (.invalidFileFormat, .invalidFileFormat),
             (.fileTooLarge, .fileTooLarge),
             (.diskFull, .diskFull),
             (.invalidData, .invalidData),
             (.decodingFailed, .decodingFailed),
             (.encodingFailed, .encodingFailed),
             (.dataCorrupted, .dataCorrupted),
             (.invalidInput, .invalidInput),
             (.authenticationRequired, .authenticationRequired),
             (.invalidCredentials, .invalidCredentials),
             (.sessionExpired, .sessionExpired),
             (.insufficientPermissions, .insufficientPermissions),
             (.pluginNotFound, .pluginNotFound),
             (.pluginLoadFailed, .pluginLoadFailed),
             (.pluginExecutionFailed, .pluginExecutionFailed),
             (.pluginIncompatible, .pluginIncompatible),
             (.mountFailed, .mountFailed),
             (.unmountFailed, .unmountFailed),
             (.mountPointInUse, .mountPointInUse),
             (.mountPointInvalid, .mountPointInvalid),
             (.unknown, .unknown),
             (.notImplemented, .notImplemented),
             (.unexpectedState, .unexpectedState),
             (.operationCancelled, .operationCancelled),
             (.rateLimitExceeded, .rateLimitExceeded),
             (.timeout, .timeout):
            return true
        default:
            return false
        }
    }
    
    // MARK: - Helper Methods
    
    /// Creates an appropriate AppError from a given Error
    public static func from(_ error: Error) -> AppError {
        if let appError = error as? AppError {
            return appError
        }
        
        let nsError = error as NSError
        
        // Map common NSError domains to AppError cases
        switch (nsError.domain, nsError.code) {
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
            return .networkError(error)
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            return .timeout
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost):
            return .networkError(error)
        case (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            return .networkError(error)
        case (NSCocoaErrorDomain, NSFileNoSuchFileError):
            return .fileNotFound("")
        case (NSCocoaErrorDomain, NSFileReadNoPermissionError):
            return .permissionDenied
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError):
            return .diskFull
        case (NSCocoaErrorDomain, 4864): // NSKeyedUnarchiveNoClassesError
            return .decodingFailed(error)
        case (NSCocoaErrorDomain, _):
            return .unknown(error)
        default:
            return .unknown(error)
        }
    }
    
    /// Returns a user-friendly error message for display in the UI
    public var userFriendlyMessage: String {
        // For now, just use the error description
        // In the future, we might want to provide more user-friendly messages
        return self.localizedDescription
    }
}
