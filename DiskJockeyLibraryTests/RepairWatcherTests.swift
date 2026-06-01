//
// RepairWatcherTests.swift — coverage for the shared repair-request
// watcher that replaced the two per-target RepairXPCService
// implementations.
//
// We exercise the synchronous portion (`handleRequest(at:)`) directly
// against temp App-Group-shaped directories. The DispatchSource +
// workQueue async hop is shared infrastructure we trust; what's
// load-bearing for behaviour preservation is the decode → runRepair
// → writeResult sequence plus the malformed-JSON fast-fail path.
//

import XCTest
@testable import DiskJockeyLibrary

final class RepairWatcherTests: XCTestCase {

    // MARK: - Fixtures

    /// One isolated trio of directories per test, matching the
    /// `Repair/<fs>/{requests,processing,responses}/` shape the
    /// real App Group container uses.
    private struct Fixture {
        let root: URL
        let requests: URL
        let processing: URL
        let responses: URL
    }

    private func makeFixture(_ name: String = #function) throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("RepairWatcherTests-\(UUID().uuidString)",
                                    isDirectory: true)
        let requests = root.appendingPathComponent("requests", isDirectory: true)
        let processing = root.appendingPathComponent("processing", isDirectory: true)
        let responses = root.appendingPathComponent("responses", isDirectory: true)
        for dir in [requests, processing, responses] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return Fixture(root: root, requests: requests,
                       processing: processing, responses: responses)
    }

    private func cleanup(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.root)
    }

    /// Drop a request file into `processing/` (skipping the
    /// requests-dir → atomic-rename step) so `handleRequest(at:)`
    /// can be invoked directly. Returns the resulting URL.
    private func dropRequest(_ request: RepairRequest,
                             into fixture: Fixture) throws -> URL {
        let url = fixture.processing.appendingPathComponent(
            DiskJockeyRepairFiles.requestFilename(id: request.id)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(request).write(to: url, options: .atomic)
        return url
    }

    /// Drop a raw payload into `processing/` with the given filename
    /// (e.g. `request-<uuid>.json`) — bypasses JSON validity so we
    /// can exercise the decode-failure recovery path.
    private func dropRawFile(named name: String, contents: Data,
                             into fixture: Fixture) throws -> URL {
        let url = fixture.processing.appendingPathComponent(name)
        try contents.write(to: url, options: .atomic)
        return url
    }

    /// Build a watcher pointing at the fixture's dirs with capture-
    /// closures for enter/exit/runRepair so each test can assert on
    /// what fired. The closures default to a successful no-op repair.
    private func makeWatcher(
        _ fixture: Fixture,
        enterCalls: NSMutableArray = NSMutableArray(),
        exitCalls: NSMutableArray = NSMutableArray(),
        runRepair: @escaping RepairWatcher.RunRepair = { request in
            RepairResult(id: request.id, success: true,
                         message: "ok", repairedCount: 0)
        }
    ) -> RepairWatcher {
        // We don't call `start()` in these tests — we drive
        // `handleRequest` directly — so the log instance only feeds
        // os_log / NDJSON sinks (no observable side effects on
        // assertions). The shared default suffices.
        RepairWatcher(
            requestsURL: fixture.requests,
            processingURL: fixture.processing,
            responsesURL: fixture.responses,
            workQueueLabel: "test.repair-watcher.\(UUID().uuidString)",
            log: AppLog.shared,
            logScope: AppLogScope.fsck,
            enterOperation: { enterCalls.add(NSDate()) },
            exitOperation: { exitCalls.add(NSDate()) },
            runRepair: runRepair
        )
    }

    private func readResult(at url: URL) throws -> RepairResult {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RepairResult.self, from: data)
    }

    // MARK: - Happy path

    func testHandleRequestDecodesInvokesRunRepairAndWritesResult() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }

        var capturedRequest: RepairRequest?
        let watcher = makeWatcher(fixture, runRepair: { request in
            capturedRequest = request
            return RepairResult(id: request.id, success: true,
                                message: "Repaired 7 anomalies.",
                                repairedCount: 7)
        })

        let request = RepairRequest(bsd: "disk5s1")
        let url = try dropRequest(request, into: fixture)

        watcher.handleRequest(at: url)

        // runRepair was invoked with the decoded request, verbatim.
        XCTAssertEqual(capturedRequest?.id, request.id)
        XCTAssertEqual(capturedRequest?.bsd, "disk5s1")

        // The processing file is gone (cleanup defer).
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // A result file exists in responses/ with the matching id.
        let resultURL = fixture.responses.appendingPathComponent(
            DiskJockeyRepairFiles.resultFilename(id: request.id)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path))
        let result = try readResult(at: resultURL)
        XCTAssertEqual(result.id, request.id)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.message, "Repaired 7 anomalies.")
        XCTAssertEqual(result.repairedCount, 7)
    }

    // MARK: - Decode failure paths

    func testHandleRequestMalformedJSONWritesFailureResultIfFilenameYieldsUUID() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }

        let watcher = makeWatcher(fixture, runRepair: { _ in
            XCTFail("runRepair must not be called when decode fails")
            return RepairResult(id: UUID(), success: false, message: "unreachable")
        })

        // Filename has a parseable UUID; payload is garbage.
        let id = UUID()
        let url = try dropRawFile(
            named: DiskJockeyRepairFiles.requestFilename(id: id),
            contents: Data("not json".utf8),
            into: fixture
        )

        watcher.handleRequest(at: url)

        // Processing file removed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // Failure result exists so the host doesn't wait the full
        // polling timeout.
        let resultURL = fixture.responses.appendingPathComponent(
            DiskJockeyRepairFiles.resultFilename(id: id)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path))
        let result = try readResult(at: resultURL)
        XCTAssertEqual(result.id, id)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("Could not decode repair request"))
    }

    func testHandleRequestMalformedJSONAndUnparseableFilenameWritesNoResult() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }

        let watcher = makeWatcher(fixture, runRepair: { _ in
            XCTFail("runRepair must not be called when decode fails")
            return RepairResult(id: UUID(), success: false, message: "unreachable")
        })

        // No UUID in the filename means the host will hit its
        // polling timeout — but the watcher refuses to invent a
        // fake response. Current behaviour: log + drop the file.
        let url = try dropRawFile(
            named: "request-not-a-uuid.json",
            contents: Data("not json".utf8),
            into: fixture
        )

        watcher.handleRequest(at: url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // No result file should have been written (we don't know
        // what UUID to address it to).
        let responses = try FileManager.default.contentsOfDirectory(
            at: fixture.responses, includingPropertiesForKeys: nil
        )
        XCTAssertTrue(responses.isEmpty,
                      "expected no result file when filename has no UUID")
    }

    // MARK: - Enter/exit hooks

    func testEnterAndExitHooksFireOnceAroundHandleRequest() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }

        let enterCalls = NSMutableArray()
        let exitCalls = NSMutableArray()
        let watcher = makeWatcher(fixture, enterCalls: enterCalls,
                                  exitCalls: exitCalls)

        let request = RepairRequest(bsd: "disk5s1")
        let url = try dropRequest(request, into: fixture)
        watcher.handleRequest(at: url)

        XCTAssertEqual(enterCalls.count, 1)
        XCTAssertEqual(exitCalls.count, 1)
    }

    func testExitHookFiresEvenWhenDecodeFails() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }

        let enterCalls = NSMutableArray()
        let exitCalls = NSMutableArray()
        let watcher = makeWatcher(fixture, enterCalls: enterCalls,
                                  exitCalls: exitCalls,
                                  runRepair: { _ in
            XCTFail("runRepair must not be called when decode fails")
            return RepairResult(id: UUID(), success: false, message: "unreachable")
        })

        let id = UUID()
        let url = try dropRawFile(
            named: DiskJockeyRepairFiles.requestFilename(id: id),
            contents: Data("not json".utf8),
            into: fixture
        )

        watcher.handleRequest(at: url)

        // Critical: the bracket invariant must hold even when the
        // request was malformed — otherwise EXT4's
        // `enterOperation`/`exitOperation` watchdog counter would
        // get out of balance and trip the parent-death exit
        // prematurely.
        XCTAssertEqual(enterCalls.count, 1)
        XCTAssertEqual(exitCalls.count, 1)
    }

    // MARK: - Result writer

    func testRunRepairFailureResultIsWrittenAsIs() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }

        let watcher = makeWatcher(fixture, runRepair: { request in
            RepairResult(id: request.id, success: false,
                         message: "Volume busy — try again.")
        })

        let request = RepairRequest(bsd: "disk5s1")
        let url = try dropRequest(request, into: fixture)
        watcher.handleRequest(at: url)

        let resultURL = fixture.responses.appendingPathComponent(
            DiskJockeyRepairFiles.resultFilename(id: request.id)
        )
        let result = try readResult(at: resultURL)
        XCTAssertEqual(result.id, request.id)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.message, "Volume busy — try again.")
        XCTAssertNil(result.repairedCount)
    }
}
