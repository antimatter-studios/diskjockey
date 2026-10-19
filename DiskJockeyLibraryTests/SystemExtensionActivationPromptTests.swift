//
//  SystemExtensionActivationPromptTests.swift — what the app tells the user,
//  and offers to do, in each activation state (diskjockey#475).
//
//  Each case drives a `SystemExtensionActivationState` into the prompt and
//  asserts the message shown and the action offered: approval opens System
//  Settings, a restart says so, and a failure names the error and retries.
//
//  Host-free: no request is submitted and SystemExtensions is not imported.
//

import Foundation
import Testing
@testable import DiskJockeyLibrary

@Suite("System extension activation prompt")
struct SystemExtensionActivationPromptTests {
    @Test func idleShowsNothing() {
        #expect(SystemExtensionActivationPrompt(state: .idle) == nil)
    }

    @Test func activatedShowsNothing() {
        #expect(SystemExtensionActivationPrompt(state: .activated) == nil)
    }

    @Test func requestingSaysItIsWaitingAndOffersNoAction() throws {
        let prompt = try #require(SystemExtensionActivationPrompt(state: .requesting))
        #expect(prompt.message.contains("Waiting for macOS"))
        #expect(prompt.action == nil)
    }

    @Test func pendingApprovalPointsAtLoginItemsAndExtensions() throws {
        let prompt = try #require(SystemExtensionActivationPrompt(state: .awaitingUserApproval))
        #expect(prompt.message.contains("System Settings > General > Login Items & Extensions"))
        #expect(prompt.action == .openLoginItemsAndExtensions)
    }

    @Test func theSettingsActionOpensTheExtensionsPane() {
        #expect(SystemExtensionActivationPrompt.loginItemsAndExtensionsURL.absoluteString
                == "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    @Test func restartRequiredSaysSoAndOffersNoAction() throws {
        let prompt = try #require(SystemExtensionActivationPrompt(state: .activatedAfterRestart))
        #expect(prompt.message.contains("Restart the Mac"))
        #expect(prompt.action == nil)
    }

    @Test func aFailureNamesTheErrorAndOffersRetry() throws {
        let prompt = try #require(SystemExtensionActivationPrompt(state: .failed(code: 8)))
        #expect(prompt.message.contains("code signature is invalid"))
        #expect(prompt.message.contains("OSSystemExtensionError 8"))
        #expect(prompt.action == .retry)
    }

    @Test func anUnknownFailureCodeStillNamesTheCode() throws {
        let prompt = try #require(SystemExtensionActivationPrompt(state: .failed(code: 99)))
        #expect(prompt.message.contains("unknown error"))
        #expect(prompt.message.contains("OSSystemExtensionError 99"))
        #expect(prompt.action == .retry)
    }

    @Test func theErrorAMountThrowsCarriesThePromptMessage() throws {
        let error = SystemExtensionActivationError(state: .awaitingUserApproval)
        let prompt = try #require(error.prompt)
        #expect(error.localizedDescription == prompt.message)
        #expect(prompt.action == .openLoginItemsAndExtensions)
    }

    @Test func approvingThePendingRequestClearsThePrompt() {
        var activation = SystemExtensionActivation()
        activation.handle(.requestSubmitted)
        activation.handle(.needsUserApproval)
        #expect(SystemExtensionActivationPrompt(state: activation.state)?.action == .openLoginItemsAndExtensions)
        activation.handle(.completed)
        #expect(SystemExtensionActivationPrompt(state: activation.state) == nil)
    }
}
