import SwiftUI
import DiskJockeyLibrary

/// A view that displays disk type-related errors with helpful recovery options
struct DiskTypeErrorView: View {
    // MARK: - Properties
    
    let error: Error
    var onDismiss: (() -> Void)?
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundColor(.yellow)
                .padding(.top)
            
            Text("Error")
                .font(.title)
                .fontWeight(.bold)
            
            Text(errorMessage)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            if let recoverySuggestion = recoverySuggestion {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Suggestion:")
                        .font(.headline)
                    Text(recoverySuggestion)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal)
            }
            
            if let onDismiss = onDismiss {
                Button(role: .cancel) {
                    onDismiss()
                } label: {
                    Text("Dismiss")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding()
        .frame(width: 400)
    }
    
    // MARK: - Error Analysis
    
    private var errorMessage: String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "Unable to connect to the internet. Please check your network connection."
            case .timedOut:
                return "The request timed out. Please try again later."
            case .cannotFindHost, .cannotConnectToHost:
                return "Unable to connect to the server. Please check the URL and try again."
            case .resourceUnavailable:
                return "The requested resource is not available."
            case .userAuthenticationRequired:
                return "Authentication is required to access this resource."
            default:
                return error.localizedDescription
            }
        } else {
            return error.localizedDescription
        }
    }
    
    private var recoverySuggestion: String? {
        if let _ = error as? URLError {
            return "Check your internet connection and try again. If the problem persists, the server may be down or the URL may be incorrect."
        }
        return nil
    }
}

// MARK: - Previews

#Preview("Network Error") {
    DiskTypeErrorView(
        error: URLError(.notConnectedToInternet),
        onDismiss: {}
    )
}

#Preview("Generic Error") {
    DiskTypeErrorView(
        error: NSError(
            domain: "com.example.error",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "An unknown error occurred."]
        ),
        onDismiss: {}
    )
}
