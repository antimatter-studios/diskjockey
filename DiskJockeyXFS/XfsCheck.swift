/*
 * XfsCheck.swift — what a check task on an XFS volume tells FSKit.
 *
 * `fsck_fskit`, and the system while it mounts a volume, reach the
 * extension's `startCheck`. The driver's checker (fs_xfs_check, which
 * XfsDriver.swift calls) reads the mounted volume and writes nothing. This
 * file holds what the task decides from what the checker reports, so that
 * `swift test` holds those decisions without the Rust library
 * (DiskJockeyXFSCore, diskjockey#196):
 *
 *   - A repair is refused before anything runs. The driver's repair is not
 *     reachable through its C ABI yet, and a check never writes.
 *   - A scan that did not reach every structure fails the task, so a
 *     volume is never reported clean after an incomplete scan (#324).
 *   - A complete scan completes the task, damaged or not, and says what it
 *     found in the `fsck.done` event the host app reads, as ext4's does.
 *
 * MIT License — see LICENSE
 */

import Foundation
import DiskJockeyLibrary

/// One finding of the driver's checker: `fs_xfs_check_finding_t`.
struct XfsCheckFinding: Equatable {
    /// The code `fsck.xfs` names it by: "checksum", "inobt.record", ...
    let code: String
    /// "error" for damage, "warning" for what is not damage.
    let severity: String
    let ag: Int64?
    let agbno: Int64?
    let ino: Int64?
    /// The on-disk field or structure, when the finding names one.
    let field: String?
    /// What is wrong, in words.
    let what: String

    /// One line for the partition log.
    var logLine: String {
        var parts = ["\(severity) \(code)"]
        if let ag { parts.append("ag=\(ag)") }
        if let agbno { parts.append("agbno=\(agbno)") }
        if let ino { parts.append("ino=\(ino)") }
        if let field { parts.append("field=\(field)") }
        return parts.joined(separator: " ") + ": " + what
    }
}

/// What the driver's checker found, in sum: `fs_xfs_check_report_t`.
struct XfsCheckReport: Equatable {
    /// Listed, each passed to the finding callback.
    var findings: UInt64 = 0
    /// Of those, errors rather than warnings.
    var errors: UInt64 = 0
    /// Found and not listed, past the checker's per-kind limit.
    var suppressed: UInt64 = 0
    var inodes: UInt64 = 0
    var directories: UInt64 = 0
    var freeBlocks: UInt64 = 0
    /// Every structure the scan reached was read.
    var complete = false
    /// The log held records not yet applied.
    var dirty = false
    /// Complete, and no error found.
    var clean = false
}

/// The driver's checker: fs_xfs_check, behind XfsDriver.
protocol XfsCheckingDriver: AnyObject {
    /// Check the mounted volume, writing nothing, and pass each finding to
    /// `onFinding`. nil when the check could not run, with the reason in
    /// `lastErrno()` and `lastErrorMessage()`.
    func check(onFinding: @escaping (XfsCheckFinding) -> Void) -> XfsCheckReport?
    func lastErrno() -> Int32
    func lastErrorMessage() -> String?
}

enum XfsCheck {
    /// Why a check task asking for `operation` is refused before anything
    /// runs, or nil when it may run.
    static func refusal(for operation: FsckOperation) -> NSError? {
        guard operation == .repair else { return nil }
        return error(.ENOTSUP,
                     "XFS repair is not available: the driver's repair is not reachable "
                     + "through its C ABI yet, and a check writes nothing")
    }

    /// Run the driver's check, and say what the task completes with: the
    /// report of a scan that reached every structure, or why there is none.
    static func run(_ driver: XfsCheckingDriver,
                    onFinding: @escaping (XfsCheckFinding) -> Void) -> Result<XfsCheckReport, NSError> {
        guard let report = driver.check(onFinding: onFinding) else {
            let code = POSIXErrorCode(rawValue: driver.lastErrno()) ?? .EIO
            let why = driver.lastErrorMessage() ?? "fs_xfs_check failed"
            return .failure(error(code, "the XFS check could not run: \(why)"))
        }
        guard report.complete else {
            return .failure(error(.EIO,
                                  "the XFS check stopped short: not every structure could be read, "
                                  + "so the volume is not known to be clean (\(report.errors) errors "
                                  + "in \(report.findings) findings before it stopped)"))
        }
        return .success(report)
    }

    /// The fields of the `fsck.done` event for a complete scan. `anomalies`
    /// is the count the host app shows, as it is for ext4.
    static func eventFields(_ report: XfsCheckReport) -> [String: String] {
        [
            "anomalies": "\(report.errors)",
            "findings": "\(report.findings)",
            "suppressed": "\(report.suppressed)",
            "inodes": "\(report.inodes)",
            "directories": "\(report.directories)",
            "free_blocks": "\(report.freeBlocks)",
            "complete": report.complete ? "true" : "false",
            "dirty": report.dirty ? "true" : "false",
            "clean": report.clean ? "true" : "false",
        ]
    }

    private static func error(_ code: POSIXErrorCode, _ message: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue),
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
