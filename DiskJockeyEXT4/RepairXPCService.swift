/*
 * RepairXPCService.swift — EXT4-side adapter around the shared
 * `RepairWatcher` in DiskJockeyLibrary.
 *
 * Despite the legacy filename, this isn't an NSXPC service — it's a
 * directory watcher on the App Group's `Repair/ext4/{requests,
 * processing,responses}/` triple. See `RepairWatcher.swift` and
 * `DiskJockeyRepairProtocol.swift` for the wire shape and rationale.
 *
 * A request asks for a repair or, since diskjockey#348, a verify: Verify on
 * a mounted volume comes here because `fsck_fskit` is refused EBUSY while
 * the volume is mounted (see EXT4Check.swift).
 *
 * What stays here:
 *   - Resolving the request's mounted volume, the throttled `onProgress`
 *     callbacks and the watchdog heartbeats around `EXT4Check.serve`,
 *     which holds what the request decides.
 *   - The bracket that registers each pass in
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

    /// Single-shot start gate. Guards the whole "ensure dirs + build
    /// watcher + call start" sequence so two concurrent `start()`
    /// callers (FSKit may invoke the principal class's init() once per
    /// mounted volume) can't construct two `RepairWatcher`s and race
    /// on the assignment, which would orphan the first instance's
    /// `DispatchSource` + open `O_EVTONLY` fd for the lifetime of the
    /// extension. Same pattern the original `RepairXPCService` used —
    /// `RepairWatcher.start()`'s own idempotency only protects the
    /// watcher's body, not the adapter's create-then-call sequence.
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
        let w = RepairWatcher(
            requestsURL: requestsURL,
            processingURL: processingURL,
            responsesURL: responsesURL,
            workQueueLabel: "com.antimatterstudios.diskjockey.ext4.repair",
            log: log,
            logScope: AppLogScope.fsck,
            enterOperation: { EXT4FileSystem.enterOperation() },
            exitOperation: { EXT4FileSystem.exitOperation() },
            runRepair: { request in Self.serve(request) }
        )
        watcher = w
        w.start()
    }

    /// Look up the live backend for `request.bsd` and serve the request:
    /// a repair, or a verify of the mounted volume (diskjockey#348). What
    /// the request decides lives in `EXT4Check`; this adds the throttled
    /// progress events and the watchdog heartbeat. Always returns a
    /// `RepairResult` — never throws.
    private static func serve(_ request: RepairRequest) -> RepairResult {
        let resolved = EXT4FileSystem.mountedResources.first { $0.bsdName == request.bsd }
        if resolved == nil {
            log.warn("RepairWatcher: no mounted ext4 volume for bsd=\(request.bsd)", scope: AppLogScope.fsck)
        }

        let dlog = TaggedLogger(
            log, fields: ["bsd": request.bsd], kind: "ext4.fsck.xpc",
            scope: AppLogScope.fsck
        )

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

        let result = EXT4Check.serve(
            request,
            on: resolved.map { EXT4CheckTarget(checker: $0.backend, opLock: $0.opLock) },
            onProgress: { phase, done, total in
                // Stuck-progress heartbeat (Fix D). Refreshes the
                // watchdog clock so a pass that's still making
                // forward progress can't trip the stuck-deadline
                // even though the log emission below is throttled.
                EXT4Watchdog.shared.heartbeat()
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
            },
            emit: { kind, fields in
                dlog.event(kind: kind, fields: fields)
            }
        )
        if !result.success {
            dlog.warn("\(request.operation.displayName) request not completed: \(result.message)")
        }
        return result
    }
}
