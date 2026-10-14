/*
 * EXT4Check.swift — a verify or repair of a MOUNTED ext4 volume, served by
 * the extension instance that holds the mount.
 *
 * The host's Verify ran `fsck_fskit -t ext4 /dev/diskN`. FSKit serves a
 * check task in a new extension instance, which opens the device again
 * (`loadResource` with `-f`, then `startCheck`); while the volume is
 * mounted that open is refused EBUSY before any extension code runs
 * (diskjockey#348). The instance that holds the mount already has the
 * driver and the device, so a verify reaches it the way a repair does: a
 * `RepairRequest` in the App Group (RepairXPCService.swift), served here
 * over the mounted volume's own driver under its `OperationLock`, as the
 * XFS check is (#324).
 *
 * This file holds what a request decides, so that `swift test` holds it
 * without the Rust library (DiskJockeyEXT4Core):
 *
 *   - A request for a volume this instance has not mounted fails.
 *   - Only a verify or a repair can be asked for; the quick check is the
 *     mount's own, through `startCheck`.
 *   - A volume already being checked answers busy, and the other
 *     operation keeps its lock.
 *   - A verify never lets the driver write; a repair does.
 *   - A scan that ran to the end completes, damaged or not, and says what
 *     it found; the `fsck.done` event carries the count to the app.
 *
 * MIT License — see LICENSE
 */

import Foundation
import DiskJockeyLibrary

/// What the driver's checker found: `fs_ext4_fsck_report_t`.
struct EXT4FsckReport: Equatable {
    let inodesVisited: UInt64
    let directoriesScanned: UInt64
    let entriesScanned: UInt64
    /// **Authoritative current** anomaly count. After a repair
    /// pass this is the post-repair re-scan count — what's still
    /// actually wrong on disk. NOT initial-minus-repaired.
    let anomaliesFound: UInt64
    let wasDirty: Bool
    let dirtyCleared: Bool
    /// Number of anomalies the repair pass committed to disk. 0
    /// when the run was read-only.
    let repairedCount: UInt64
    /// Anomalies the audit found BEFORE any repair commits.
    /// Equal to `anomaliesFound` for non-repair runs. After a
    /// repair pass: `initialAnomaliesFound - repairedCount` is
    /// what we EXPECT to remain; `anomaliesFound` is what
    /// ACTUALLY remains. A discrepancy flags repair-logic bugs.
    let initialAnomaliesFound: UInt64

    /// Format the report as `fsck.done` event fields. Mirrors
    /// `NTFSVolume.FsckReport.toEventFields()` — both include
    /// `dirty_cleared` so the host app's
    /// `AttachedDisksModel.applyEventInPlace`
    /// consumes either with the same code path.
    func toEventFields() -> [String: String] {
        return [
            "dirty_cleared":           dirtyCleared ? "true" : "false",
            "anomalies":               "\(anomaliesFound)",
            "directories":             "\(directoriesScanned)",
            "inodes":                  "\(inodesVisited)",
            "repaired_count":          "\(repairedCount)",
            "initial_anomalies_count": "\(initialAnomaliesFound)",
        ]
    }
}

/// One finding of the driver's checker.
struct EXT4FsckFinding: Equatable {
    /// One of "link_count_low", "link_count_high", "dangling_entry",
    /// "wrong_dotdot", "bogus_entry", "duplicate_dir_inode"
    /// (Rust-emitted strings — do NOT extend without coordinating
    /// with the Rust crate's `anomaly_to_capi`).
    let kind: String
    let inode: UInt32
    let detail: String
}

/// The driver's checker over the mounted volume: EXT4Backend.runFsck.
protocol EXT4CheckingBackend: AnyObject {
    func runFsck(repair: Bool,
                 onProgress: @escaping (_ phase: String, _ done: UInt64, _ total: UInt64) -> Void,
                 onFinding: @escaping (EXT4FsckFinding) -> Void) -> Result<EXT4FsckReport, Error>
}

/// The mounted volume a request is served on.
struct EXT4CheckTarget {
    let checker: EXT4CheckingBackend
    let opLock: OperationLock
}

enum EXT4Check {
    /// Serve `request` on `target`, the volume this instance mounted for
    /// `request.bsd` (nil when it mounted none). Synchronous: the caller's
    /// scope is the operation's lifetime. `emit` receives the `fsck.*`
    /// events the host's per-disk view consumes.
    static func serve(_ request: RepairRequest,
                      on target: EXT4CheckTarget?,
                      onProgress: @escaping (_ phase: String, _ done: UInt64, _ total: UInt64) -> Void,
                      onFinding: @escaping (EXT4FsckFinding) -> Void,
                      emit: (_ kind: String, _ fields: [String: String]) -> Void) -> RepairResult {
        guard let target else {
            return RepairResult(id: request.id, success: false,
                                message: "no mounted ext4 volume for bsd=\(request.bsd) — is the disk still attached?")
        }
        let operation = request.operation
        guard operation == .verify || operation == .repair else {
            return RepairResult(id: request.id, success: false,
                                message: "a request can ask for a verify or a repair, not a \(operation.displayName)")
        }
        // Cooperative mutex: a refused request never held the lock, so it
        // must not release it.
        if let busy = target.opLock.tryAcquire(operation) {
            return RepairResult(id: request.id, success: false,
                                message: "Volume busy with \(busy.displayName) — try again when it finishes.")
        }
        defer { target.opLock.release() }

        let repair = operation == .repair
        emit("fsck.start", ["repair": repair ? "true" : "false"])
        switch target.checker.runFsck(repair: repair, onProgress: onProgress, onFinding: onFinding) {
        case .success(let report):
            emit("fsck.done", report.toEventFields())
            return RepairResult(id: request.id, success: true,
                                message: summary(report, repaired: repair),
                                repairedCount: repair ? report.repairedCount : nil)
        case .failure(let error):
            emit("fsck.failed", ["error": error.localizedDescription])
            return RepairResult(id: request.id, success: false, message: error.localizedDescription)
        }
    }

    /// The line the host shows when the pass completes.
    static func summary(_ report: EXT4FsckReport, repaired: Bool) -> String {
        if repaired {
            let n = report.repairedCount
            return n == 1 ? "Repaired 1 anomaly." : "Repaired \(n) anomalies."
        }
        switch report.anomaliesFound {
        case 0: return "Verified: no problems found."
        case 1: return "Verified: found 1 problem."
        case let n: return "Verified: found \(n) problems."
        }
    }
}
