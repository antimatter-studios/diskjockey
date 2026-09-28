//
//  TestHostTests.swift — the app, launched as the test host, starts none
//  of its own machinery.
//
//  WHY (diskjockey#101). The runner timeout was the app's own main thread.
//  A spindump Xcode took of the stuck host (runs 36415323755 and
//  36415318318, every one of ~500 samples) shows the main queue inside
//  RawDisksModel.refresh() -> runDiskutil -> ProcessRunner.run, waiting on
//  `diskutil info` for one disk after another; the 3-second poll timer
//  queues the next refresh before the last one ends on a slow runner. XCTest
//  prepares its execution worker on that same main queue, so it never got a
//  turn, and xcodebuild gave up after 300 seconds without progress. Nothing
//  the tests exercise needs the app delegate, the container or its pollers.
//

import AppKit
import Testing
@testable import DiskJockey

@MainActor
struct TestHostStartsNothingTests {
    @Test func theHostHasNoAppDelegate() {
        #expect(NSApp.delegate == nil, "the test host built its AppDelegate, so AppContainer's disk pollers are competing with XCTest for the main thread (diskjockey#101)")
    }
}
