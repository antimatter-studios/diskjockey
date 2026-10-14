//
//  EXT4CheckTests.swift — a verify or repair of a MOUNTED ext4 volume,
//  served by the extension instance that holds the mount (diskjockey#348).
//
//  WHY THIS EXISTS
//  ---------------
//  Verify on a mounted ext4 volume failed with "Resource busy". The host ran
//  `fsck_fskit -t ext4 /dev/diskN`, and FSKit runs every check task in a NEW
//  extension instance: the extension's own log shows the mount's quick check
//  arriving in a process that first calls `loadResource` with `-f` on a
//  read-only device, then `startCheck`. With the volume already mounted,
//  that second open of the device is refused EBUSY before any extension
//  code runs, so nothing the extension's `startCheck` does can answer it.
//
//  The instance that holds the mount already has the driver and the
//  device. A verify is therefore carried to it the way a repair is: a
//  request in the App Group, served over the mounted volume's own driver
//  under its `OperationLock`, as the XFS check is (#324).
//
//  Host-free: the real EXT4Check over a checker that records what it is
//  asked, the way XfsCheckTests drives XfsCheck.
//

import Foundation
import Testing
@testable import DiskJockeyEXT4Core
import DiskJockeyLibrary

/// A checker that answers what the test says and records each run,
/// including which operation held the volume's lock while it ran.
private final class StubChecker: EXT4CheckingBackend {
    let opLock: OperationLock
    var result: Result<EXT4FsckReport, Error>
    var findings: [EXT4FsckFinding] = []
    private(set) var runs: [Bool] = []
    private(set) var heldDuringRun: [FsckOperation?] = []

    init(opLock: OperationLock, result: Result<EXT4FsckReport, Error>) {
        self.opLock = opLock
        self.result = result
    }

    func runFsck(repair: Bool,
                 onProgress: @escaping (_ phase: String, _ done: UInt64, _ total: UInt64) -> Void,
                 onFinding: @escaping (EXT4FsckFinding) -> Void) -> Result<EXT4FsckReport, Error> {
        runs.append(repair)
        heldDuringRun.append(opLock.current)
        onProgress("directory", 1, 1)
        findings.forEach(onFinding)
        return result
    }
}

private func report(anomalies: UInt64 = 0, repaired: UInt64 = 0, initial: UInt64? = nil) -> EXT4FsckReport {
    EXT4FsckReport(inodesVisited: 260, directoriesScanned: 3, entriesScanned: 12,
                   anomaliesFound: anomalies, wasDirty: false, dirtyCleared: false,
                   repairedCount: repaired, initialAnomaliesFound: initial ?? anomalies)
}

private struct Served {
    let result: RepairResult
    let events: [(kind: String, fields: [String: String])]
    let progress: [String]
    let findings: [EXT4FsckFinding]
}

private func serve(_ request: RepairRequest, on target: EXT4CheckTarget?) -> Served {
    var events: [(kind: String, fields: [String: String])] = []
    var progress: [String] = []
    var findings: [EXT4FsckFinding] = []
    let result = EXT4Check.serve(
        request, on: target,
        onProgress: { phase, _, _ in progress.append(phase) },
        onFinding: { findings.append($0) },
        emit: { kind, fields in events.append((kind, fields)) })
    return Served(result: result, events: events, progress: progress, findings: findings)
}

@Suite("A check of a mounted ext4 volume runs in the instance that mounted it (#348)")
struct EXT4CheckTests {

    @Test("a verify runs the mounted volume's checker read-only, holding the volume's lock as a verify")
    func verifyRunsOnTheMountedVolume() {
        let lock = OperationLock()
        let checker = StubChecker(opLock: lock, result: .success(report()))
        let request = RepairRequest(bsd: "disk9", operation: .verify)

        let served = serve(request, on: EXT4CheckTarget(checker: checker, opLock: lock))

        #expect(checker.runs == [false], "a verify must never ask the driver to write")
        #expect(checker.heldDuringRun == [.verify],
                "the volume answers its own operations EBUSY while the scan runs, so nothing changes under it")
        #expect(lock.current == nil, "the lock is released when the verify ends")
        #expect(served.result.id == request.id)
        #expect(served.result.success)
        #expect(served.result.repairedCount == nil, "a verify repairs nothing, so it reports no repaired count")
        #expect(served.progress == ["directory"])
    }

    @Test("a verify says what it found, and the app's fsck.done event carries the count")
    func verifyReportsWhatItFound() throws {
        let lock = OperationLock()
        let finding = EXT4FsckFinding(kind: "link_count_low", inode: 14, detail: "links 1, entries 2")
        let checker = StubChecker(opLock: lock, result: .success(report(anomalies: 3)))
        checker.findings = [finding]

        let served = serve(RepairRequest(bsd: "disk9", operation: .verify),
                           on: EXT4CheckTarget(checker: checker, opLock: lock))

        #expect(served.result.success, "a scan that ran to the end completes, damaged or not")
        #expect(served.result.message.contains("3"), "the result names how many problems the scan found")
        #expect(served.findings == [finding])
        #expect(served.events.map { $0.kind } == ["fsck.start", "fsck.done"])
        #expect(served.events.first?.fields["repair"] == "false")
        let done = try #require(served.events.last)
        #expect(done.fields["anomalies"] == "3")
    }

    @Test("a clean verify says the volume has no problems")
    func cleanVerify() {
        let lock = OperationLock()
        let served = serve(RepairRequest(bsd: "disk9", operation: .verify),
                           on: EXT4CheckTarget(checker: StubChecker(opLock: lock, result: .success(report())),
                                               opLock: lock))
        #expect(served.result.success)
        #expect(served.result.message == "Verified: no problems found.")
    }

    @Test("a repair runs the checker with writes allowed, holding the lock as a repair")
    func repairWrites() {
        let lock = OperationLock()
        let checker = StubChecker(opLock: lock, result: .success(report(anomalies: 0, repaired: 2, initial: 2)))

        let served = serve(RepairRequest(bsd: "disk9", operation: .repair),
                           on: EXT4CheckTarget(checker: checker, opLock: lock))

        #expect(checker.runs == [true])
        #expect(checker.heldDuringRun == [.repair])
        #expect(lock.current == nil)
        #expect(served.result.success)
        #expect(served.result.repairedCount == 2)
        #expect(served.result.message == "Repaired 2 anomalies.")
        #expect(served.events.first?.fields["repair"] == "true")
    }

    @Test("a volume already being checked answers busy, runs nothing, and keeps the other operation's lock")
    func busyVolume() {
        let lock = OperationLock()
        #expect(lock.tryAcquire(.repair) == nil)
        let checker = StubChecker(opLock: lock, result: .success(report()))

        let served = serve(RepairRequest(bsd: "disk9", operation: .verify),
                           on: EXT4CheckTarget(checker: checker, opLock: lock))

        #expect(checker.runs.isEmpty)
        #expect(!served.result.success)
        #expect(served.result.message.contains("repair"), "the refusal names what the volume is busy with")
        #expect(lock.current == .repair, "a refused request must not release a lock it never held")
        #expect(served.events.isEmpty)
    }

    @Test("a request for a volume this instance has not mounted fails without running anything")
    func noMountedVolume() {
        let served = serve(RepairRequest(bsd: "disk9", operation: .verify), on: nil)
        #expect(!served.result.success)
        #expect(served.result.message.contains("disk9"))
        #expect(served.events.isEmpty)
    }

    @Test("a checker that fails fails the request, says why, and releases the lock")
    func checkerFails() {
        let lock = OperationLock()
        let why = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO),
                          userInfo: [NSLocalizedDescriptionKey: "the inode table could not be read"])
        let checker = StubChecker(opLock: lock, result: .failure(why))

        let served = serve(RepairRequest(bsd: "disk9", operation: .verify),
                           on: EXT4CheckTarget(checker: checker, opLock: lock))

        #expect(!served.result.success)
        #expect(served.result.message == "the inode table could not be read")
        #expect(served.events.map { $0.kind } == ["fsck.start", "fsck.failed"])
        #expect(lock.current == nil)
    }

    @Test("the mount's quick check is not something a request can ask for")
    func quickCheckIsRefused() {
        let lock = OperationLock()
        let checker = StubChecker(opLock: lock, result: .success(report()))

        let served = serve(RepairRequest(bsd: "disk9", operation: .quickCheck),
                           on: EXT4CheckTarget(checker: checker, opLock: lock))

        #expect(checker.runs.isEmpty)
        #expect(!served.result.success)
        #expect(lock.current == nil)
    }
}
