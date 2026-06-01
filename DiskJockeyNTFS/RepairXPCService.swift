/*
 * RepairXPCService.swift — NTFS-side adapter around the shared
 * `RepairWatcher` in DiskJockeyLibrary. Mirror of the EXT4 sibling.
 *
 * The driver's repair pass isn't wired yet — `fs_ntfs_fsck_with_callbacks`
 * does dirty-bit/$LogFile work but not metadata repair. Until that
 * lands, every request gets a truthful "not implemented" response so
 * the host app surfaces an honest error rather than faking success.
 */

import Foundation
import os
import DiskJockeyLibrary

final class RepairXPCService: NSObject {

    static let shared = RepairXPCService()

    /// Single-shot start gate. See EXT4 sibling for the full rationale
    /// — short version: prevents two concurrent `start()` callers from
    /// constructing two `RepairWatcher`s and racing on `self.watcher`,
    /// which would orphan the first watcher's `DispatchSource` + fd.
    private let startedLock = OSAllocatedUnfairLock(initialState: false)
    private var watcher: RepairWatcher?

    func start() {
        let shouldStart: Bool = startedLock.withLock { started in
            if started { return false }
            started = true
            return true
        }
        guard shouldStart else { return }

        do {
            try DiskJockeyRepairFiles.ensureDirectories(forFsType: "ntfs")
        } catch {
            log.error("RepairWatcher: ensureDirectories failed: \(error.localizedDescription)",
                      scope: AppLogScope.fsck)
            return
        }
        guard
            let requestsURL = DiskJockeyRepairFiles.requestsURL(forFsType: "ntfs"),
            let processingURL = DiskJockeyRepairFiles.processingURL(forFsType: "ntfs"),
            let responsesURL = DiskJockeyRepairFiles.responsesURL(forFsType: "ntfs")
        else {
            log.error("RepairWatcher: App Group container unreachable",
                      scope: AppLogScope.fsck)
            return
        }
        let w = RepairWatcher(
            requestsURL: requestsURL,
            processingURL: processingURL,
            responsesURL: responsesURL,
            workQueueLabel: "com.antimatterstudios.diskjockey.ntfs.repair",
            log: log,
            logScope: AppLogScope.fsck,
            runRepair: { request in Self.runRepair(for: request) }
        )
        watcher = w
        w.start()
    }

    private static func runRepair(for request: RepairRequest) -> RepairResult {
        let resolved = NTFSFileSystem.mountedResources.first { $0.bsdName == request.bsd }
        guard resolved != nil else {
            let msg = "no mounted ntfs volume for bsd=\(request.bsd) — is the disk still attached?"
            log.warn("RepairWatcher: \(msg)", scope: AppLogScope.fsck)
            return RepairResult(id: request.id, success: false, message: msg)
        }
        // Truthful "not implemented" — see file header.
        let msg = "In-process repair for NTFS isn't implemented yet — track follow-up work in the NTFS crate."
        log.warn("RepairWatcher: \(msg)", scope: AppLogScope.fsck)
        return RepairResult(id: request.id, success: false, message: msg)
    }
}
