import Foundation

/// An error type that represents errors that can occur when interacting with the backend.
public enum BackendError: LocalizedError, Equatable {
    // MARK: - Process Errors
    case processNotRunning
    case processAlreadyRunning
    case processStartupFailed(Error?)
    case processTerminationFailed(Error?)
    case processUnexpectedTermination
    case processTimeout
    case processInvalidState
    case processLaunchFailed(Error)
    
    // MARK: - Connection Errors
    case connectionFailed(Error?)
    case connectionLost(Error?)
    case connectionTimeout
    case connectionRefused
    case connectionCancelled
    case connectionInvalid
    
    // MARK: - Protocol Errors
    case invalidMessageFormat
    case unsupportedMessageType
    case messageSerializationFailed(Error?)
    case messageDeserializationFailed(Error?)
    case invalidResponse
    case unexpectedResponse
    case requestTimeout
    
    // MARK: - Authentication & Authorization
    case authenticationFailed(String?)
    case authorizationFailed(String?)
    case invalidToken
    case tokenExpired
    
    // MARK: - Resource Errors
    case resourceNotFound(String?)
    case resourceAlreadyExists(String?)
    case resourceUnavailable
    case resourceBusy
    case resourceLimitExceeded
    
    // MARK: - Operation Errors
    case operationNotSupported
    case operationFailed(String?)
    case operationCancelled
    case operationTimeout
    case operationNotPermitted
    case operationInProgress
    
    // MARK: - Configuration Errors
    case invalidConfiguration(String?)
    case missingConfiguration(String?)
    case configurationLoadFailed(Error?)
    
    // MARK: - Error Descriptions
    
    public var errorDescription: String? {
        switch self {
        // Process Errors
        case .processNotRunning:
            return "The backend process is not running."
        case .processAlreadyRunning:
            return "The backend process is already running."
        case .processStartupFailed(let error):
            if let error = error {
                return "Failed to start backend process: \(error.localizedDescription)"
            } else {
                return "Failed to start backend process."
            }
        case .processTerminationFailed(let error):
            if let error = error {
                return "Failed to terminate backend process: \(error.localizedDescription)"
            } else {
                return "Failed to terminate backend process."
            }
        case .processUnexpectedTermination:
            return "The backend process terminated unexpectedly."
        case .processTimeout:
            return "The backend process did not start within the expected time."
        case .processInvalidState:
            return "The backend process is in an invalid state."
        case .processLaunchFailed(let error):
            return "Failed to launch backend process: \(error.localizedDescription)"
            
        // Connection Errors
        case .connectionFailed(let error):
            if let error = error {
                return "Failed to connect to backend: \(error.localizedDescription)"
            } else {
                return "Failed to connect to backend."
            }
        case .connectionLost(let error):
            if let error = error {
                return "Connection to backend lost: \(error.localizedDescription)"
            } else {
                return "Connection to backend lost."
            }
        case .connectionTimeout:
            return "Connection to backend timed out."
        case .connectionRefused:
            return "Connection to backend was refused."
        case .connectionCancelled:
            return "Connection to backend was cancelled."
        case .connectionInvalid:
            return "The connection to the backend is invalid."
            
        // Protocol Errors
        case .invalidMessageFormat:
            return "Received a message with an invalid format."
        case .unsupportedMessageType:
            return "Received an unsupported message type."
        case .messageSerializationFailed(let error):
            if let error = error {
                return "Failed to serialize message: \(error.localizedDescription)"
            } else {
                return "Failed to serialize message."
            }
        case .messageDeserializationFailed(let error):
            if let error = error {
                return "Failed to deserialize message: \(error.localizedDescription)"
            } else {
                return "Failed to deserialize message."
            }
        case .invalidResponse:
            return "Received an invalid response from the backend."
        case .unexpectedResponse:
            return "Received an unexpected response from the backend."
        case .requestTimeout:
            return "The request to the backend timed out."
            
        // Authentication & Authorization
        case .authenticationFailed(let message):
            return message ?? "Authentication failed."
        case .authorizationFailed(let message):
            return message ?? "Authorization failed."
        case .invalidToken:
            return "The authentication token is invalid."
        case .tokenExpired:
            return "The authentication token has expired."
            
        // Resource Errors
        case .resourceNotFound(let resource):
            if let resource = resource {
                return "Resource not found: \(resource)"
            } else {
                return "Resource not found."
            }
        case .resourceAlreadyExists(let resource):
            if let resource = resource {
                return "Resource already exists: \(resource)"
            } else {
                return "Resource already exists."
            }
        case .resourceUnavailable:
            return "The requested resource is currently unavailable."
        case .resourceBusy:
            return "The requested resource is busy."
        case .resourceLimitExceeded:
            return "The resource limit has been exceeded."
            
        // Operation Errors
        case .operationNotSupported:
            return "The requested operation is not supported."
        case .operationFailed(let message):
            return message ?? "The operation failed."
        case .operationCancelled:
            return "The operation was cancelled."
        case .operationTimeout:
            return "The operation timed out."
        case .operationNotPermitted:
            return "The operation is not permitted."
        case .operationInProgress:
            return "The operation is already in progress."
            
        // Configuration Errors
        case .invalidConfiguration(let message):
            if let message = message {
                return "Invalid configuration: \(message)"
            } else {
                return "Invalid configuration."
            }
        case .missingConfiguration(let key):
            if let key = key {
                return "Missing required configuration: \(key)"
            } else {
                return "Missing required configuration."
            }
        case .configurationLoadFailed(let error):
            if let error = error {
                return "Failed to load configuration: \(error.localizedDescription)"
            } else {
                return "Failed to load configuration."
            }
        }
    }
    
    // MARK: - Equatable
    
    public static func == (lhs: BackendError, rhs: BackendError) -> Bool {
        switch (lhs, rhs) {
        case (.processNotRunning, .processNotRunning),
             (.processAlreadyRunning, .processAlreadyRunning),
             (.processStartupFailed, .processStartupFailed),
             (.processTerminationFailed, .processTerminationFailed),
             (.processUnexpectedTermination, .processUnexpectedTermination),
             (.processTimeout, .processTimeout),
             (.processInvalidState, .processInvalidState),
             (.processLaunchFailed, .processLaunchFailed),
             (.connectionFailed, .connectionFailed),
             (.connectionLost, .connectionLost),
             (.connectionTimeout, .connectionTimeout),
             (.connectionRefused, .connectionRefused),
             (.connectionCancelled, .connectionCancelled),
             (.connectionInvalid, .connectionInvalid),
             (.invalidMessageFormat, .invalidMessageFormat),
             (.unsupportedMessageType, .unsupportedMessageType),
             (.messageSerializationFailed, .messageSerializationFailed),
             (.messageDeserializationFailed, .messageDeserializationFailed),
             (.invalidResponse, .invalidResponse),
             (.unexpectedResponse, .unexpectedResponse),
             (.requestTimeout, .requestTimeout),
             (.authenticationFailed, .authenticationFailed),
             (.authorizationFailed, .authorizationFailed),
             (.invalidToken, .invalidToken),
             (.tokenExpired, .tokenExpired),
             (.resourceNotFound, .resourceNotFound),
             (.resourceAlreadyExists, .resourceAlreadyExists),
             (.resourceUnavailable, .resourceUnavailable),
             (.resourceBusy, .resourceBusy),
             (.resourceLimitExceeded, .resourceLimitExceeded),
             (.operationNotSupported, .operationNotSupported),
             (.operationFailed, .operationFailed),
             (.operationCancelled, .operationCancelled),
             (.operationTimeout, .operationTimeout),
             (.operationNotPermitted, .operationNotPermitted),
             (.operationInProgress, .operationInProgress),
             (.invalidConfiguration, .invalidConfiguration),
             (.missingConfiguration, .missingConfiguration),
             (.configurationLoadFailed, .configurationLoadFailed):
            return true
        default:
            return false
        }
    }
    
    // MARK: - Helper Methods
    
    /// Creates a BackendError from a given Error
    public static func from(_ error: Error) -> BackendError {
        if let backendError = error as? BackendError {
            return backendError
        }
        
        let nsError = error as NSError
        
        // Map common NSError domains to BackendError cases
        switch (nsError.domain, nsError.code) {
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            return .connectionTimeout
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost):
            return .connectionFailed(error)
        case (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            return .connectionLost(error)
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
            return .connectionFailed(error)
        case (NSURLErrorDomain, NSURLErrorCancelled):
            return .connectionCancelled
        case (NSCocoaErrorDomain, _):
            return .operationFailed(error.localizedDescription)
        default:
            return .operationFailed(error.localizedDescription)
        }
    }
    
    /// Returns a user-friendly error message for display in the UI
    public var userFriendlyMessage: String {
        // For now, just use the error description
        // In the future, we might want to provide more user-friendly messages
        return self.localizedDescription
    }
}
