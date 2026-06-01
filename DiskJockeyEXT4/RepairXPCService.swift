/*
 * RepairXPCService.swift — EXT4-side adapter around the shared
 * `RepairWatcher` in DiskJockeyLibrary.
 *
 * Despite the legacy filename, this isn't an NSXPC service — it's a
 * directory watcher on the App Group's `Repair/ext4/{requests,
 * processing,responses}/` triple. See `RepairWatcher.swift` and
 * `DiskJockeyRepairProtocol.swift` for the wire shape and rationale.
 *
 * What stays here:
 *   - The EXT4-specific `runRepair` body (`backend.runFsck` + throttled
 *     `onProgress` callbacks + watchdog heartbeats).
 *   - The bracket that registers each repair pass in
 *     `DetachedOperationWatchdog` via `enterOperation` / `exitOperation`.
 *
 * Everything else (FD-watcher binding, atomic-rename-as-claim, JSON
 * decode + fallback, atomic result write) lives in
 * `DiskJockeyLibrary/RepairWatcher.swift`.
 */

import Foundation
import os
import DiskJockeyLibrary

final class RepairXPCService: NSObject {

    static let shared = RepairXPCService()

    private var watcher: RepairWatcher?

    func start() {
        // The watcher is built lazily on first start() so the App
        // Group directories can be ensured before we hand resolved
        // URLs to RepairWatcher.init.
        if watcher == nil {
            do {
                try DiskJockeyRepairFiles.ensureDirectories(forFsType: "ext4")
            } catch {
                log.error("RepairWatcher: ensureDirectories failed: \(error.localizedDescription)",
                          scope: AppLogScope.fsck)
                return
            }
            guard
                let requestsURL = DiskJockeyRepairFiles.requestsURL(forFsType: "ext4"),
                let processingURL = DiskJockeyRepairFiles.processingURL(forFsType: "ext4"),
                let responsesURL = DiskJockeyRepairFiles.responsesURL(forFsType: "ext4")
            else {
                log.error("RepairWatcher: App Group container unreachable",
                          scope: AppLogScope.fsck)
                return
            }
            watcher = RepairWatcher(
                requestsURL: requestsURL,
                processingURL: processingURL,
                responsesURL: responsesURL,
                workQueueLabel: "com.antimatterstudios.diskjockey.ext4.repair",
                log: log,
                logScope: AppLogScope.fsck,
                enterOperation: { EXT4FileSystem.enterOperation() },
                exitOperation: { EXT4FileSystem.exitOperation() },
                runRepair: { request in Self.runRepair(for: request) }
            )
        }
        watcher?.start()
    }

    /// Look up the live backend for `request.bsd` and run the repair
    /// pass. Always returns a `RepairResult` — never throws.
    private static func runRepair(for request: RepairRequest) -> RepairResult {
        let resolved = EXT4FileSystem.mountedResources.first { $0.bsdName == request.bsd }

        guard let resolved = resolved else {
            let msg = "no mounted ext4 volume for bsd=\(request.bsd) — is the disk still attached?"
            log.warn("RepairWatcher: \(msg)", scope: AppLogScope.fsck)
            return RepairResult(id: request.id, success: false, message: msg)
        }

        let dlog = TaggedLogger(
            log, fields: ["bsd": request.bsd], kind: "ext4.fsck.xpc",
            scope: AppLogScope.fsck
        )

        // Cooperative tri-state mutex. Reject if a verify (via
        // fsck_fskit) or another repair is already in flight. The
        // matching release is via `defer` on this scope — runFsck is
        // synchronous, so this scope IS the operation lifetime.
        if let busy = resolved.opLock.tryAcquire(.repair) {
            let msg = "Volume busy with \(busy.displayName) — try again when it finishes."
            dlog.warn("repair rejected: \(msg)")
            return RepairResult(id: request.id, success: false, message: msg)
        }
        defer { resolved.opLock.release() }

        dlog.event(kind: "fsck.start", fields: ["repair": "true"])

        // Rust's audit_with_repair fires `onProgress` once per dirent
        // — on a large volume that's tens of thousands of callbacks
        // per second. Each fsck.progress event we emit ends up
        // routed to the host app's main actor (LogTailService →
        // applyExtensionEvent → SwiftUI rerender), so unthrottled
        // emission floods the main runloop and beachballs the UI.
        //
        // Throttle the emission rate. The default (verboseRepairLog
        // off) is conservative — 1 Hz — which is plenty to keep the
        // UI's progress bar moving without dumping megabytes of
        // events into the log. Flip the toggle on (in the host app's
        // diagnostics section) to crank it up to 10 Hz when
        // collecting traces for a hard-to-reproduce repair bug.
        // Phase boundaries (`done == total`) and phase changes
        // always emit regardless of throttle so the pipeline advance
        // remains visible.
        let appGroupDefaults = UserDefaults(suiteName: AppLog.groupIdentifier)
        let verbose = appGroupDefaults?.bool(forKey: "verboseRepairLog") ?? false
        var lastEmitMonotonic: UInt64 = 0
        var lastPhase: String = ""
        let minIntervalNs: UInt64 = verbose ? 100_000_000 : 1_000_000_000  // 10 Hz vs 1 Hz

        let runResult = resolved.backend.runFsck(
            repair: true,
            onProgress: { phase, done, total in
                // Stuck-progress heartbeat (Fix D). Refreshes the
                // watchdog clock so a repair that's still making
                // forward progress can't trip the stuck-deadline
                // even though the log emission below is throttled.
                EXT4FileSystem.watchdog.heartbeat()
                // Throttle. Only two carve-outs that bypass the time
                // gate: a phase CHANGE (so the user sees the
                // pipeline advance) and the FIRST emit (so the
                // progress bar appears immediately). We deliberately
                // do NOT carve out `done == total` — for the
                // directory phase the Rust crate calls onProgress
                // with that condition at the end of every single
                // directory it walks, which on a multi-thousand-dir
                // volume produces thousands of emits per second and
                // floods the host's main runloop.
                let now = monotonicNanos()
                let phaseChanged = phase != lastPhase
                let intervalElapsed = lastEmitMonotonic == 0
                    || (now &- lastEmitMonotonic) >= minIntervalNs
                guard phaseChanged || intervalElapsed else { return }
                lastEmitMonotonic = now
                lastPhase = phase
                dlog.event(kind: "fsck.progress", fields: [
                    "phase": phase,
                    "done":  "\(done)",
                    "total": "\(total)",
                ])
            },
            onFinding: { f in
                dlog.warn("fsck finding: kind=\(f.kind) inode=\(f.inode) \(f.detail)")
            }
        )

        switch runResult {
        case .success(let report):
            dlog.event(kind: "fsck.done", fields: report.toEventFields())
            let n = report.repairedCount
            let summary = n == 1 ? "Repaired 1 anomaly." : "Repaired \(n) anomalies."
            return RepairResult(id: request.id, success: true, message: summary, repairedCount: n)
        case .failure(let err):
            dlog.event(kind: "fsck.failed", fields: ["error": err.localizedDescription])
            return RepairResult(id: request.id, success: false, message: err.localizedDescription)
        }
    }
}
