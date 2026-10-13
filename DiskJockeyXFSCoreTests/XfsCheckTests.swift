import Foundation
import FSKit
import Testing
@testable import DiskJockeyXFSCore
import DiskJockeyLibrary

/// A driver whose checker answers what the test says, and whose every
/// other call fails ENOENT.
private final class CheckDriver: XfsMountedVolumeDriver, XfsCheckingDriver {
    var report: XfsCheckReport?
    var findings: [XfsCheckFinding] = []
    var errno: Int32 = ENOENT
    var message: String?
    var checks = 0

    var isWritable = false
    func volumeInfo() -> ReadOnlyVolumeInfo? { nil }
    func stat(_ path: VolumePath) -> ReadOnlyFileAttributes? { nil }
    func walkDirectory(_ path: VolumePath,
                       _ visit: (ReadOnlyDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk { .finished }
    func read(_ path: VolumePath, at offset: UInt64,
              into buffer: UnsafeMutableRawBufferPointer) -> Int64 { -1 }
    func readlink(_ path: VolumePath, _ buffer: UnsafeMutablePointer<CChar>, _ size: Int) -> Int32 { -1 }
    func write(_ path: VolumePath, at offset: UInt64,
               from buffer: UnsafeRawBufferPointer) -> Int64 { -1 }
    func truncate(_ path: VolumePath, to size: UInt64, modified: timespec?) -> Int32 { -1 }
    func flush() -> Int32 { -1 }
    func create(_ path: VolumePath, mode: UInt16) -> UInt64 { 0 }
    func mkdir(_ path: VolumePath, mode: UInt16) -> UInt64 { 0 }
    func unlink(_ path: VolumePath) -> Int32 { -1 }
    func rmdir(_ path: VolumePath) -> Int32 { -1 }
    func link(_ source: VolumePath, to destination: VolumePath) -> Int32 { -1 }
    func rename(_ source: VolumePath, to destination: VolumePath, replace: Bool) -> Int32 { -1 }
    func setAttributes(_ path: VolumePath, mode: UInt32?, uid: UInt32?, gid: UInt32?,
                       accessed: timespec?, modified: timespec?) -> Int32 { -1 }
    func getXattr(_ path: VolumePath, name: [UInt8]) -> [UInt8]? { nil }
    func listXattrs(_ path: VolumePath) -> [[UInt8]]? { nil }
    func setXattr(_ path: VolumePath, name: [UInt8], value: [UInt8], flags: Int32) -> Int32 { -1 }
    func removeXattr(_ path: VolumePath, name: [UInt8]) -> Int32 { -1 }
    func lastErrno() -> Int32 { errno }
    func lastErrorMessage() -> String? { message }
    func unmount() {}

    func check(onFinding: @escaping (XfsCheckFinding) -> Void) -> XfsCheckReport? {
        checks += 1
        findings.forEach(onFinding)
        return report
    }
}

private let damage = XfsCheckFinding(code: "inobt.chunk-count", severity: "error", ag: 0, agbno: nil,
                                     ino: nil, field: nil,
                                     what: "the inode chunk at 128 counts 70 free inodes, but its free mask has 52")
private let notice = XfsCheckFinding(code: "sb.copy.uuid", severity: "warning", ag: 1, agbno: 0, ino: nil,
                                     field: "sb_uuid", what: "a secondary superblock names another filesystem")

private func run(_ driver: CheckDriver) -> (Result<XfsCheckReport, NSError>, [XfsCheckFinding]) {
    var seen: [XfsCheckFinding] = []
    let result = XfsCheck.run(driver, onFinding: { seen.append($0) })
    return (result, seen)
}

/// What an FSKit check task on an XFS volume reports, from what the
/// driver's checker found (diskjockey#324). The checker writes nothing; a
/// scan that did not reach every structure never reports clean.
@Suite("XFS check task")
struct XfsCheckTests {

    @Test func aRepairIsRefusedBeforeAnythingRuns() {
        let refused = XfsCheck.refusal(for: .repair)
        #expect(refused?.domain == NSPOSIXErrorDomain)
        #expect(refused?.code == Int(ENOTSUP))
    }

    @Test(arguments: [FsckOperation.verify, .quickCheck])
    func aCheckThatWritesNothingMayRun(_ operation: FsckOperation) {
        #expect(XfsCheck.refusal(for: operation) == nil)
    }

    @Test func aCleanVolumeCompletesClean() throws {
        let driver = CheckDriver()
        driver.report = XfsCheckReport(inodes: 415, directories: 4, freeBlocks: 108_593,
                                       complete: true, clean: true)
        let (result, seen) = run(driver)
        let report = try result.get()
        #expect(seen.isEmpty)
        let fields = XfsCheck.eventFields(report)
        #expect(fields["clean"] == "true")
        #expect(fields["complete"] == "true")
        #expect(fields["anomalies"] == "0")
        #expect(fields["inodes"] == "415")
        #expect(fields["directories"] == "4")
        #expect(fields["free_blocks"] == "108593")
    }

    /// Damage found by a scan that read everything completes the task, as
    /// ext4's does, and the count of errors is what the host app shows.
    @Test func aDamagedVolumeReportsEveryFindingAndItsErrors() throws {
        let driver = CheckDriver()
        driver.findings = [damage, notice]
        driver.report = XfsCheckReport(findings: 2, errors: 1, suppressed: 3, inodes: 415,
                                       directories: 4, complete: true, clean: false)
        let (result, seen) = run(driver)
        let report = try result.get()
        #expect(seen == [damage, notice])
        let fields = XfsCheck.eventFields(report)
        #expect(fields["clean"] == "false")
        #expect(fields["anomalies"] == "1")
        #expect(fields["findings"] == "2")
        #expect(fields["suppressed"] == "3")
    }

    @Test func aDirtyLogIsSaid() throws {
        let driver = CheckDriver()
        driver.report = XfsCheckReport(complete: true, dirty: true, clean: false)
        let (result, _) = run(driver)
        #expect(XfsCheck.eventFields(try result.get())["dirty"] == "true")
    }

    /// The whole point of #324's last clause: a check that stopped short
    /// fails the task, whatever the report beside it says.
    @Test(arguments: [false, true])
    func aScanThatStoppedShortIsNeverClean(_ reportedClean: Bool) {
        let driver = CheckDriver()
        driver.findings = [damage]
        driver.report = XfsCheckReport(findings: 1, errors: 1, complete: false, clean: reportedClean)
        let (result, seen) = run(driver)
        #expect(seen == [damage])
        guard case .failure(let error) = result else {
            Issue.record("an incomplete scan completed the task")
            return
        }
        #expect(error.code == Int(EIO))
        #expect(error.localizedDescription.contains("stopped short"))
    }

    @Test func aCheckThatCouldNotRunSaysWhy() {
        let driver = CheckDriver()
        driver.report = nil
        driver.errno = ENODEV
        driver.message = "the device went away"
        let (result, _) = run(driver)
        guard case .failure(let error) = result else {
            Issue.record("a check that could not run completed the task")
            return
        }
        #expect(error.code == Int(ENODEV))
        #expect(error.localizedDescription.contains("the device went away"))
    }

    @Test func aCheckThatCouldNotRunWithNoErrnoIsAnIOError() {
        let driver = CheckDriver()
        driver.report = nil
        driver.errno = 0
        let (result, _) = run(driver)
        guard case .failure(let error) = result else {
            Issue.record("a check that could not run completed the task")
            return
        }
        #expect(error.code == Int(EIO))
    }

    @Test func aFindingIsOneLogLineNamingWhereItIs() {
        #expect(damage.logLine
            == "error inobt.chunk-count ag=0: the inode chunk at 128 counts 70 free inodes, but its free mask has 52")
        #expect(notice.logLine
            == "warning sb.copy.uuid ag=1 agbno=0 field=sb_uuid: a secondary superblock names another filesystem")
    }
}

/// While a verify holds the volume's lock, the volume answers EBUSY rather
/// than read or change what is being checked. The quick check the system
/// runs while mounting does not hold it off (diskjockey#166).
@Suite("XFS volume during a check")
struct XfsVolumeCheckLockTests {

    private func fixture(_ lock: OperationLock) -> (XfsVolume, XfsItem) {
        let volume = XfsVolume(volumeID: FSVolume.Identifier(), volumeName: FSFileName(string: "check"),
                               driver: CheckDriver(), contextPtr: nil, bsdName: "check-test",
                               stats: IOStatsCollector(label: "check-test", emit: { _ in }),
                               opLock: lock)
        return (volume, volume.item(forInode: 128, path: .root, parentInode: nil))
    }

    private func code(_ body: () async throws -> Void) async -> POSIXErrorCode? {
        do { try await body(); return nil } catch let e as POSIXError { return e.code } catch { return nil }
    }

    @Test(arguments: [FsckOperation.verify, .repair])
    func aCheckThatQuiescesTheVolumeRefusesItsOperations(_ operation: FsckOperation) async {
        let lock = OperationLock()
        let (volume, root) = fixture(lock)
        #expect(lock.tryAcquire(operation) == nil)
        #expect(await code { _ = try await volume.lookupItem(named: FSFileName(string: "a"), inDirectory: root) }
            == .EBUSY)
        #expect(await code { _ = try await volume.readSymbolicLink(root) } == .EBUSY)
        #expect(await code { _ = try await volume.xattrs(of: root) } == .EBUSY)
    }

    @Test func theMountsQuickCheckLetsItsOperationsThrough() async {
        let lock = OperationLock()
        let (volume, root) = fixture(lock)
        #expect(lock.tryAcquire(.quickCheck) == nil)
        // It reaches the driver, which has no such name.
        #expect(await code { _ = try await volume.lookupItem(named: FSFileName(string: "a"), inDirectory: root) }
            == .ENOENT)
    }

    @Test func aReleasedLockLetsOperationsThrough() async {
        let lock = OperationLock()
        let (volume, root) = fixture(lock)
        #expect(lock.tryAcquire(.verify) == nil)
        lock.release()
        #expect(await code { _ = try await volume.lookupItem(named: FSFileName(string: "a"), inDirectory: root) }
            == .ENOENT)
    }
}
