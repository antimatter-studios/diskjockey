//
//  TestHostTests.swift — recognising the process Xcode launches to host
//  the app-hosted test bundle, from its environment alone.
//
//  The in-host half of this contract is DiskJockeyTests/TestHostTests.swift:
//  these cases pin the decision, that one proves Xcode's real launcher sets
//  what the decision reads.
//

import Testing
@testable import DiskJockeyLibrary

struct TestHostTests {
    /// What Xcode injects into a TEST_HOST process on macOS.
    private static let inject =
        "/Applications/Xcode.app/Contents/Developer/usr/lib/libXCTestBundleInject.dylib"

    @Test func anOrdinaryLaunchIsNotATestHost() {
        #expect(TestHost.isHostingTests(environment: [:]) == false)
        #expect(TestHost.isHostingTests(environment: ["HOME": "/Users/x", "PATH": "/usr/bin"]) == false)
    }

    @Test func theInjectedTestBundleLoaderMarksATestHost() {
        #expect(TestHost.isHostingTests(environment: ["DYLD_INSERT_LIBRARIES": Self.inject]))
        #expect(TestHost.isHostingTests(environment: ["DYLD_INSERT_LIBRARIES": "/a/libother.dylib:" + Self.inject]))
    }

    @Test func anUnrelatedInsertedLibraryIsNotATestHost() {
        #expect(TestHost.isHostingTests(environment: ["DYLD_INSERT_LIBRARIES": "/usr/lib/libgmalloc.dylib"]) == false)
    }

    @Test(arguments: ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"])
    func eachXCTestSessionVariableMarksATestHost(key: String) {
        #expect(TestHost.isHostingTests(environment: [key: "/tmp/x"]))
    }

    @Test(arguments: ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier", "DYLD_INSERT_LIBRARIES"])
    func anEmptyValueIsNotATestHost(key: String) {
        #expect(TestHost.isHostingTests(environment: [key: ""]) == false)
    }
}
