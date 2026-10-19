//
// SystemExtensionActivationPrompt.swift — what the app tells the user, and
// offers to do, in each `SystemExtensionActivationState` (diskjockey#475).
//
// A mount that needs the virtual disk system extension fails with
// `SystemExtensionActivationError` until the extension is active; the view
// shows the prompt that error carries instead of a bare error string, so
// each state the user can act on comes with the action that resolves it.
//

import Foundation

public struct SystemExtensionActivationPrompt: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Open System Settings > General > Login Items & Extensions, where
        /// the user allows the extension.
        case openLoginItemsAndExtensions
        /// Submit a new activation request by mounting again.
        case retry
    }

    /// The Login Items & Extensions pane of System Settings.
    public static let loginItemsAndExtensionsURL =
        URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    public let title: String
    public let message: String
    public let action: Action?

    /// `nil` when there is nothing to tell the user: before a request, and
    /// once the extension is active.
    public init?(state: SystemExtensionActivationState) {
        switch state {
        case .idle, .activated:
            return nil
        case .requesting:
            title = "Activating the virtual disk"
            message = "Waiting for macOS to activate the DiskJockey virtual disk."
            action = nil
        case .awaitingUserApproval:
            title = "Allow the virtual disk"
            message = "Allow the DiskJockey virtual disk in System Settings > General > Login Items & Extensions, then mount the image again."
            action = .openLoginItemsAndExtensions
        case .activatedAfterRestart:
            title = "Restart to finish installing"
            message = "The DiskJockey virtual disk finishes installing after a restart. Restart the Mac, then mount the image again."
            action = nil
        case .failed(let code):
            title = "The virtual disk could not be activated"
            message = "The DiskJockey virtual disk could not be activated: \(Self.reason(code: code)) (OSSystemExtensionError \(code))."
            action = .retry
        }
    }

    /// The `OSSystemExtensionError.Code` raw values, as SystemExtensions'
    /// OSSystemExtensionErrorCode declares them, in words.
    static func reason(code: Int) -> String {
        switch code {
        case 2: return "the app is missing the system extension install entitlement"
        case 3: return "the app must be in the Applications folder"
        case 4: return "the extension is not in the app bundle"
        case 5: return "the extension has no bundle identifier"
        case 6: return "two extensions share one bundle identifier"
        case 7: return "the extension's category is unknown"
        case 8: return "the extension's code signature is invalid"
        case 9: return "the extension failed validation"
        case 10: return "system policy forbids the extension"
        case 11: return "the request was cancelled"
        case 12: return "a newer request replaced this one"
        case 13: return "administrator authorization is required"
        default: return "an unknown error"
        }
    }
}

/// What a mount throws while the virtual disk extension is not active.
public struct SystemExtensionActivationError: LocalizedError, Equatable, Sendable {
    public let state: SystemExtensionActivationState

    public init(state: SystemExtensionActivationState) {
        self.state = state
    }

    public var prompt: SystemExtensionActivationPrompt? {
        SystemExtensionActivationPrompt(state: state)
    }

    public var errorDescription: String? {
        prompt?.message ?? "The DiskJockey virtual disk is not active."
    }
}
