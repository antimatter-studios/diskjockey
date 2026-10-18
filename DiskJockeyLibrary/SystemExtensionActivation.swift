//
// SystemExtensionActivation.swift — the state the app shows while the
// virtual disk system extension is activated.
//
// The app submits an `OSSystemExtensionRequest` and feeds each delegate
// callback here as an event. The model holds no SystemExtensions objects,
// so every transition is testable without submitting a request.
//
// Apple does not promise the callback order, and a request can outlive the
// view that started it, so the rules are:
//   - a callback with no request outstanding is ignored;
//   - once a request reaches a terminal state, a late callback does not
//     change it;
//   - a new request after a terminal state starts over, and a duplicate
//     request while one is pending does not forget pending approval.
//

import Foundation

public enum SystemExtensionActivationState: Equatable, Sendable {
    case idle
    case requesting
    /// `requestNeedsUserApproval`: the user must allow the extension in
    /// System Settings before the request can complete.
    case awaitingUserApproval
    /// `didFinishWithResult(.completed)`.
    case activated
    /// `didFinishWithResult(.willCompleteAfterReboot)`.
    case activatedAfterRestart
    /// `didFailWithError`, carrying the `OSSystemExtensionError` code.
    case failed(code: Int)

    public var isTerminal: Bool {
        switch self {
        case .idle, .requesting, .awaitingUserApproval: return false
        case .activated, .activatedAfterRestart, .failed: return true
        }
    }
}

public enum SystemExtensionActivationEvent: Equatable, Sendable {
    case requestSubmitted
    case needsUserApproval
    case completed
    case willCompleteAfterReboot
    case failed(code: Int)
}

/// The answer to `actionForReplacingExtension(_:withExtension:)`.
public enum SystemExtensionReplacementDecision: Equatable, Sendable {
    case replace
    case cancel
}

public struct SystemExtensionActivation: Sendable {
    public private(set) var state: SystemExtensionActivationState = .idle

    public init() {}

    public mutating func handle(_ event: SystemExtensionActivationEvent) {
        switch (state, event) {
        case (.idle, .requestSubmitted):
            state = .requesting
        case (_, .requestSubmitted) where state.isTerminal:
            state = .requesting
        case (.idle, _), (_, .requestSubmitted):
            return
        case (_, _) where state.isTerminal:
            return
        case (_, .needsUserApproval):
            state = .awaitingUserApproval
        case (_, .completed):
            state = .activated
        case (_, .willCompleteAfterReboot):
            state = .activatedAfterRestart
        case (_, .failed(let code)):
            state = .failed(code: code)
        }
    }

    /// Replace the installed extension unless the bundled one is older: a
    /// stale copy of the app must not downgrade a newer installed driver.
    /// Versions are `CFBundleVersion` strings, compared numerically.
    public static func replacementDecision(
        installedVersion: String,
        bundledVersion: String
    ) -> SystemExtensionReplacementDecision {
        bundledVersion.compare(installedVersion, options: .numeric) == .orderedAscending
            ? .cancel : .replace
    }
}
