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
 *   - A repair runs the driver's repair over the volume's device
 *     (fs_xfs_repair_with_fs_core_device), with the mounted driver let go
 *     first and the device mounted again afterwards (XfsVolume.repairDevice).
 *     It is refused on a device that cannot be written.
 *   - A repair cancelled through the task's Progress fails the task with
 *     ECANCELED: the driver is told to stop at its next item, which the
 *     driver's ABI promises is before anything is written.
 *   - A repair that the driver refuses, or that leaves damage it does not
 *     repair, fails the task: the volume is reported clean only when the
 *     driver checks it clean after the repair.
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

/// One item of the driver's repair: `fs_xfs_repair_item_t`.
struct XfsRepairItem: Equatable {
    /// "change", "refusal" or "unplanned".
    let kind: String
    /// The finding code it concerns, as `fsck.xfs` names it.
    let code: String
    /// For a change, the rule that proposed it.
    let rule: String?
    /// For a change, the device byte offset it writes.
    let offset: Int64?
    /// For a change, how many bytes it writes.
    let length: UInt64
    /// Why, in words.
    let what: String

    /// One line for the partition log.
    var logLine: String {
        var parts = ["\(kind) \(code)"]
        if let rule { parts.append("rule=\(rule)") }
        if let offset { parts.append("offset=\(offset) length=\(length)") }
        return parts.joined(separator: " ") + ": " + what
    }
}

/// What the driver's repair planned and did: `fs_xfs_repair_report_t`.
struct XfsRepairReport: Equatable {
    /// A plan was made; false when the driver refused to repair.
    var ready = false
    var changes: UInt64 = 0
    var refusals: UInt64 = 0
    /// Error findings no rule of the driver repairs.
    var unplanned: UInt64 = 0
    var written: UInt64 = 0
    /// The volume, checked after the repair, was checked in full and clean.
    var clean = false
}

/// The driver's repair over the volume's device:
/// fs_xfs_repair_with_fs_core_device, behind XfsDeviceRepair.
protocol XfsRepairingDevice: AnyObject {
    /// Plan a repair and write it, passing each change, refusal and
    /// unplanned finding to `onItem`. `shouldStop` is asked after each item;
    /// true stops the listing and cancels the repair before anything is
    /// written. nil when it could not run, with the reason in `lastErrno()`
    /// and `lastErrorMessage()`.
    func repair(onItem: @escaping (XfsRepairItem) -> Void,
                shouldStop: @escaping () -> Bool) -> XfsRepairReport?
    func lastErrno() -> Int32
    func lastErrorMessage() -> String?
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
    /// runs, or nil when it may run. A repair writes the device, so one on a
    /// device that cannot be written is refused.
    static func refusal(for operation: FsckOperation, deviceIsWritable: Bool) -> NSError? {
        guard operation == .repair, !deviceIsWritable else { return nil }
        return error(.EROFS, "XFS repair writes the device, and this one cannot be written")
    }

    /// Run the driver's repair, and say what the task completes with: the
    /// report of a repair that left the volume clean, or why it did not.
    /// `isCancelled` is the task's cancellation: asked before the repair
    /// starts and after each item, so a cancel stops the driver before it
    /// writes, and the task fails with ECANCELED.
    static func runRepair(_ device: XfsRepairingDevice,
                          isCancelled: @escaping () -> Bool = { false },
                          onItem: @escaping (XfsRepairItem) -> Void) -> Result<XfsRepairReport, NSError> {
        if isCancelled() {
            return .failure(error(.ECANCELED, "the XFS repair was cancelled before it ran; nothing was written"))
        }
        var stopped = false
        let report = device.repair(onItem: onItem, shouldStop: {
            if isCancelled() { stopped = true }
            return stopped
        })
        guard let report else {
            let code = POSIXErrorCode(rawValue: device.lastErrno()) ?? .EIO
            let why = device.lastErrorMessage() ?? "fs_xfs_repair_with_fs_core_device failed"
            return .failure(error(code, "the XFS repair could not run: \(why)"))
        }
        if stopped {
            return .failure(error(.ECANCELED,
                                  "the XFS repair was cancelled; \(report.written) of \(report.changes) "
                                  + "changes were written"))
        }
        guard report.ready else {
            return .failure(error(.EIO,
                                  "the XFS repair was refused (\(report.refusals) reasons, in the "
                                  + "partition log); nothing was written"))
        }
        guard report.clean else {
            return .failure(error(.EIO,
                                  "the XFS repair wrote \(report.written) of \(report.changes) changes, "
                                  + "and \(report.unplanned) errors it does not repair remain, so the "
                                  + "volume is not clean"))
        }
        return .success(report)
    }

    /// The fields of the `fsck.done` event for a repair that left the
    /// volume clean: `repaired_count` is the count the host app shows.
    static func repairEventFields(_ report: XfsRepairReport) -> [String: String] {
        [
            "repaired_count": "\(report.written)",
            "anomalies": "\(report.unplanned)",
            "changes": "\(report.changes)",
            "clean": report.clean ? "true" : "false",
        ]
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
