import Foundation
import OSLog
import SystemExtensions
import DiskJockeyLibrary

/// Activates the virtual disk system extension the first time a qcow2 or
/// VHDX image is mounted, never at launch: someone who only mounts raw, VHD
/// or VMDK images is never asked to approve a driver (diskjockey#474).
///
/// Each delegate callback feeds `SystemExtensionActivation`, the host-free
/// model the library tests drive; this class only submits the request and
/// wakes the mounts waiting on it. What a mount throws is
/// `SystemExtensionActivationError`, whose prompt the view shows (#475).
@MainActor
final class SystemExtensionActivator: NSObject {
    static let shared = SystemExtensionActivator()

    /// The dext's PRODUCT_BUNDLE_IDENTIFIER. scripts/tests/
    /// system-extension-activation.sh holds it to the embedded target.
    static let identifier = "com.antimatterstudios.diskjockey.virtualdisk"

    private let logger = Logger(subsystem: "com.antimatterstudios.diskjockey", category: "SystemExtension")
    private var activation = SystemExtensionActivation()
    private var waiters: [CheckedContinuation<Void, Error>] = []
    /// Set when the installed extension is newer than the bundled one: the
    /// cancelled replacement then leaves a working driver, not a failure.
    private var declinedDowngrade = false

    var state: SystemExtensionActivationState { activation.state }

    /// Returns once the extension is active. Throws when the user must
    /// approve it or restart first, or when activation failed; a later call
    /// after a failure submits a new request.
    func activate() async throws {
        switch activation.state {
        case .activated:
            return
        case .awaitingUserApproval, .activatedAfterRestart:
            throw SystemExtensionActivationError(state: activation.state)
        case .requesting:
            break
        case .idle, .failed:
            activation.handle(.requestSubmitted)
            declinedDowngrade = false
            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: Self.identifier, queue: .main)
            request.delegate = self
            logger.info("submitting activation request for \(Self.identifier, privacy: .public)")
            OSSystemExtensionManager.shared.submitRequest(request)
        }
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    private func handle(_ event: SystemExtensionActivationEvent) {
        activation.handle(event)
        let result: Result<Void, Error>
        switch activation.state {
        case .idle, .requesting:
            return
        case .activated:
            result = .success(())
        case .awaitingUserApproval, .activatedAfterRestart:
            result = .failure(SystemExtensionActivationError(state: activation.state))
        case .failed(let code):
            logger.error("activation failed: OSSystemExtensionError \(code, privacy: .public)")
            result = .failure(SystemExtensionActivationError(state: activation.state))
        }
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed { waiter.resume(with: result) }
    }
}

// Callbacks arrive on the main queue named in `activationRequest`.
extension SystemExtensionActivator: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        switch SystemExtensionActivation.replacementDecision(installedVersion: existing.bundleVersion,
                                                             bundledVersion: ext.bundleVersion) {
        case .replace:
            return .replace
        case .cancel:
            MainActor.assumeIsolated { declinedDowngrade = true }
            return .cancel
        }
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { handle(.needsUserApproval) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let event: SystemExtensionActivationEvent =
            result == .willCompleteAfterReboot ? .willCompleteAfterReboot : .completed
        MainActor.assumeIsolated { handle(event) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let code = (error as NSError).code
        MainActor.assumeIsolated {
            if declinedDowngrade && code == OSSystemExtensionError.Code.requestCanceled.rawValue {
                handle(.completed)
            } else {
                handle(.failed(code: code))
            }
        }
    }
}
