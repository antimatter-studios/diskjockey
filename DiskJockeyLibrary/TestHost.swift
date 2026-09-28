//
//  TestHost.swift — is this process the one Xcode launched to host a test
//  bundle?
//
//  WHY IT EXISTS (diskjockey#101)
//
//  DiskJockeyTests sets TEST_HOST to the app, so `xcodebuild test` launches
//  DiskJockey.app and injects the bundle into it. The app then did what it
//  does for a person: built AppContainer, which starts polling `diskutil`
//  and `mount` every three seconds, synchronously, on the main actor. On a
//  slow CI runner one `diskutil info` pass over every disk outlasts the
//  poll interval, so the main queue never drains. XCTest prepares its
//  execution worker on that same queue, and xcodebuild gave up with
//
//      The test runner timed out while preparing to run tests.
//
//  The spindump Xcode attached to that failure has the main thread inside
//  RawDisksModel.refresh() -> ProcessRunner.run in every sample. The app
//  entry point asks this type first and, in a test host, starts nothing.
//
//  WHAT IT READS
//
//  Xcode's launcher sets these in the host's environment and nothing else
//  does: the bundle-injection library, and the XCTest session variables.
//  Any one is enough. A non-empty value is required, so an exported but
//  blank variable in a person's shell does not silence their app.
//

import Foundation

public enum TestHost {
    /// Variables Xcode's test launcher sets in the host process.
    static let sessionVariables = [
        "XCTestConfigurationFilePath",
        "XCTestBundlePath",
        "XCTestSessionIdentifier",
    ]

    /// The library Xcode inserts to load the test bundle into the host.
    static let injectLibrary = "libXCTestBundleInject"

    /// True when `environment` is that of a process hosting XCTest.
    public static func isHostingTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        for key in sessionVariables where !(environment[key] ?? "").isEmpty {
            return true
        }
        return (environment["DYLD_INSERT_LIBRARIES"] ?? "").contains(injectLibrary)
    }
}
