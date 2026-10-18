//
//  SystemExtensionActivationTests.swift — the state the app shows while
//  the virtual disk system extension is activated (diskjockey#473).
//
//  The delegate callbacks of `OSSystemExtensionRequest` arrive in an order
//  Apple does not promise, and a request can outlive the view that started
//  it. Each case here pins one transition, including the ones a late or
//  duplicate callback could otherwise get wrong.
//
//  Host-free: no request is submitted and SystemExtensions is not imported.
//

import Testing
@testable import DiskJockeyLibrary

@Suite("System extension activation")
struct SystemExtensionActivationTests {
    private func run(_ events: [SystemExtensionActivationEvent]) -> SystemExtensionActivationState {
        var activation = SystemExtensionActivation()
        for event in events { activation.handle(event) }
        return activation.state
    }

    @Test func aNewActivationIsIdle() {
        #expect(SystemExtensionActivation().state == .idle)
    }

    @Test func submittingARequestIsRequesting() {
        #expect(run([.requestSubmitted]) == .requesting)
    }

    @Test func completionWithoutApprovalIsActivated() {
        #expect(run([.requestSubmitted, .completed]) == .activated)
    }

    @Test func approvalRequiredThenCompletedIsActivated() {
        #expect(run([.requestSubmitted, .needsUserApproval]) == .awaitingUserApproval)
        #expect(run([.requestSubmitted, .needsUserApproval, .completed]) == .activated)
    }

    @Test func restartRequiredIsItsOwnState() {
        #expect(run([.requestSubmitted, .willCompleteAfterReboot]) == .activatedAfterRestart)
        #expect(run([.requestSubmitted, .needsUserApproval, .willCompleteAfterReboot]) == .activatedAfterRestart)
    }

    @Test(arguments: [1, 4, 8, 11])
    func failureKeepsTheErrorCode(code: Int) {
        #expect(run([.requestSubmitted, .failed(code: code)]) == .failed(code: code))
        #expect(run([.requestSubmitted, .needsUserApproval, .failed(code: code)]) == .failed(code: code))
    }

    @Test func aLateCallbackDoesNotRegressATerminalState() {
        #expect(run([.requestSubmitted, .completed, .needsUserApproval]) == .activated)
        #expect(run([.requestSubmitted, .completed, .failed(code: 1)]) == .activated)
        #expect(run([.requestSubmitted, .failed(code: 4), .completed]) == .failed(code: 4))
        #expect(run([.requestSubmitted, .willCompleteAfterReboot, .completed]) == .activatedAfterRestart)
    }

    @Test func callbacksWithoutARequestAreIgnored() {
        #expect(run([.needsUserApproval]) == .idle)
        #expect(run([.completed]) == .idle)
        #expect(run([.failed(code: 1)]) == .idle)
    }

    @Test func aDuplicateSubmitDoesNotForgetPendingApproval() {
        #expect(run([.requestSubmitted, .needsUserApproval, .requestSubmitted]) == .awaitingUserApproval)
    }

    @Test func aNewRequestAfterATerminalStateStartsOver() {
        #expect(run([.requestSubmitted, .failed(code: 1), .requestSubmitted]) == .requesting)
        #expect(run([.requestSubmitted, .completed, .requestSubmitted]) == .requesting)
    }

    @Test func terminalStatesAreTerminal() {
        #expect(!SystemExtensionActivationState.idle.isTerminal)
        #expect(!SystemExtensionActivationState.requesting.isTerminal)
        #expect(!SystemExtensionActivationState.awaitingUserApproval.isTerminal)
        #expect(SystemExtensionActivationState.activated.isTerminal)
        #expect(SystemExtensionActivationState.activatedAfterRestart.isTerminal)
        #expect(SystemExtensionActivationState.failed(code: 1).isTerminal)
    }

    @Test func aNewerOrEqualBundleReplacesTheInstalledOne() {
        #expect(SystemExtensionActivation.replacementDecision(installedVersion: "41", bundledVersion: "42") == .replace)
        #expect(SystemExtensionActivation.replacementDecision(installedVersion: "42", bundledVersion: "42") == .replace)
        #expect(SystemExtensionActivation.replacementDecision(installedVersion: "9", bundledVersion: "10") == .replace)
        #expect(SystemExtensionActivation.replacementDecision(installedVersion: "1.2.9", bundledVersion: "1.2.10") == .replace)
    }

    @Test func anOlderBundleNeverDowngradesTheInstalledOne() {
        #expect(SystemExtensionActivation.replacementDecision(installedVersion: "42", bundledVersion: "41") == .cancel)
        #expect(SystemExtensionActivation.replacementDecision(installedVersion: "10", bundledVersion: "9") == .cancel)
        #expect(SystemExtensionActivation.replacementDecision(installedVersion: "1.2.10", bundledVersion: "1.2.9") == .cancel)
    }
}
