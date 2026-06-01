/*
 * RepairXPCService.swift — file-based repair watcher inside the EXT4
 * FSKit extension. Despite the legacy filename, this is no longer an
 * NSXPC service — it's a directory watcher on the shared App Group
 * container.
 *
 * The host app drops a JSON request file into
 *   <App Group>/Repair/ext4/requests/request-<uuid>.json
 * The watcher claims it (atomic rename into `processing/`), runs the
 * journaled repair pass against the live mount, and writes the
 * result alongside the original UUID into
 *   <App Group>/Repair/ext4/responses/result-<uuid>.json
 *
 * Progress events keep flowing through the existing NDJSON log file
 * — the host's LogTailService picks them up and pipes them into the
 * per-disk detail view's progress UI without touching this file.
 *
 * Why files instead of XPC: ExtensionKit-extension bundles silently
 * ignore Info.plist `MachServices` declarations, and anonymous
 * NSXPCListener + endpoint serialization (while public-API and
 * documented) is unconventional enough to risk reviewer-friction
 * at App Store review. Two of our own bundles communicating
 * through their shared App Group container is the textbook use
 * of App Groups — uncontroversial and MAS-defensible.
 */

import Foundation
import os
import DiskJockeyLibrary

private extension String {
    func deletingPrefix(_ p: String) -> String {
        hasPrefix(p) ? String(dropFirst(p.count)) : self
    }
    func deletingSuffix(_ s: String) -> String {
        hasSuffix(s) ? String(dropLast(s.count)) : self
    }
}

final class RepairXPCService: NSObject {

    static let shared = RepairXPCService()

    private let lock = OSAllocatedUnfairLock(initialState: false)
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: CInt = -1
    private let workQueue = DispatchQueue(
        label: "com.antimatterstudios.diskjockey.ext4.repair",
        qos: .userInitiated
    )

    func start() {
        // Idempotent — the principal class's init() may run once per
        // mounted volume, but only the first call binds the watcher.
        let shouldStart: Bool = lock.withLock { started in
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
        guard let requestsURL = DiskJockeyRepairFiles.requestsURL(forFsType: "ext4") else {
            log.error("RepairWatcher: App Group container unreachable",
                      scope: AppLogScope.fsck)
            return
        }

        // Sweep on startup — if the extension was killed mid-flight
        // last session, requests may be in `processing/` waiting to be
        // re-tried, and there may be pending requests already in
        // `requests/` that arrived while we weren't running.
        scanAndProcess()

        // Watch the requests directory for new arrivals. DispatchSource
        // on the directory FD fires on .write events when entries are
        // added/removed — cheaper than polling and reacts in
        // milliseconds.
        let fd = open(requestsURL.path, O_EVTONLY)
        if fd < 0 {
            let errStr = String(cString: strerror(errno))
            log.error("RepairWatcher: open(\(requestsURL.path)) failed: \(errStr)",
                      scope: AppLogScope.fsck)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: workQueue
        )
        source.setEventHandler { [weak self] in
            self?.scanAndProcess()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()

        self.watchedFD = fd
        self.watcher = source

        log.info("RepairWatcher: watching \(requestsURL.path)",
                 scope: AppLogScope.fsck)
    }

    /// Scan `requests/`, claim each pending file by atomic-renaming
    /// it into `processing/`, and dispatch the repair onto the work
    /// queue. Every transition is logged so the host's per-disk log
    /// strip can render the pipeline state in real time.
    private func scanAndProcess() {
        guard
            let requestsURL = DiskJockeyRepairFiles.requestsURL(forFsType: "ext4"),
            let processingURL = DiskJockeyRepairFiles.processingURL(forFsType: "ext4")
        else { return }

        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: requestsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            log.error("RepairWatcher: cannot list \(requestsURL.path): \(error.localizedDescription)",
                      scope: AppLogScope.fsck)
            return
        }

        for src in entries where src.lastPathComponent.hasPrefix("request-") {
            let dst = processingURL.appendingPathComponent(src.lastPathComponent)
            do {
                // Atomic rename — concurrent watchers (or a stuck
                // previous run) lose the race and find the file
                // already claimed.
                try fm.moveItem(at: src, to: dst)
                log.info("RepairWatcher: claimed \(src.lastPathComponent) → processing/",
                         scope: AppLogScope.fsck)
            } catch {
                // Lost the race; another worker has it. Log and
                // continue so this is visible if it ever recurs.
                log.info("RepairWatcher: skipped \(src.lastPathComponent) (already claimed): \(error.localizedDescription)",
                         scope: AppLogScope.fsck)
                continue
            }
            workQueue.async { [weak self] in
                self?.handleRequest(at: dst)
            }
        }
    }

    /// Decode the request file, run the repair, write the result.
    /// Always cleans up the in-flight file at the end.
    private func handleRequest(at processingURL: URL) {
        // Track in the parent-death watchdog counter: repair runs
        // synchronously inside `runFsck`, which holds the per-handle
        // state lock and has no cancel hook on the Rust side. If the
        // host or mount goes away mid-repair, the watchdog will exit
        // the appex once the deadline elapses.
        EXT4FileSystem.enterOperation()
        defer {
            // Best-effort cleanup. If unlink fails the next start() will
            // see a stale processing entry and re-process; idempotent on
            // the result side because `result-<uuid>.json` overwrites.
            try? FileManager.default.removeItem(at: processingURL)
            EXT4FileSystem.exitOperation()
        }

        let request: RepairRequest
        do {
            let data = try Data(contentsOf: processingURL)
            let decoder = JSONDecoder()
            // Match the host's encoder (ISO 8601 dates). Without this,
            // decode fails with "data couldn't be read because it
            // isn't in the correct format" and the host waits the
            // full polling timeout for a result that never comes.
            decoder.dateDecodingStrategy = .iso8601
            request = try decoder.decode(RepairRequest.self, from: data)
            log.info("RepairWatcher: decoded request id=\(request.id) bsd=\(request.bsd)",
                     scope: AppLogScope.fsck)
        } catch {
            // Decode failure is fatal for this request. Try to recover
            // the request id from the filename so the host gets a fast
            // failure result instead of a 30-minute timeout. Filename
            // shape is `request-<uuid>.json`.
            let filename = processingURL.lastPathComponent
            let recoveredID = filename
                .deletingPrefix("request-")
                .deletingSuffix(".json")
            log.error("RepairWatcher: decode failed for \(filename): \(error.localizedDescription) — replying with failure result so the host doesn't wait the full timeout",
                      scope: AppLogScope.fsck)
            if let uuid = UUID(uuidString: recoveredID) {
                writeResult(
                    RepairResult(
                        id: uuid,
                        success: false,
                        message: "Could not decode repair request: \(error.localizedDescription)"),
                    for: uuid
                )
            } else {
                log.error("RepairWatcher: filename did not yield a parseable UUID — host will hit polling timeout",
                          scope: AppLogScope.fsck)
            }
            return
        }

        log.info("RepairWatcher: starting repair for request id=\(request.id) bsd=\(request.bsd)",
                 scope: AppLogScope.fsck)
        let result = runRepair(for: request)
        log.info("RepairWatcher: repair finished for id=\(request.id) bsd=\(request.bsd) success=\(result.success) repaired=\(result.repairedCount.map { "\($0)" } ?? "-")",
                 scope: AppLogScope.fsck)
        writeResult(result, for: request.id)
    }

    /// Look up the live backend for `request.bsd` and run the repair
    /// pass. Always returns a `RepairResult` — never throws.
    private func runRepair(for request: RepairRequest) -> RepairResult {
        let resolved: EXT4FileSystem.MountedResource? = EXT4FileSystem.mountedResources.withLock { map in
            map.values.first(where: { $0.bsdName == request.bsd })
        }

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

    /// Write the result file. Atomic so the host's watcher never
    /// reads a partial JSON.
    private func writeResult(_ result: RepairResult, for id: UUID) {
        guard let responsesURL = DiskJockeyRepairFiles.responsesURL(forFsType: "ext4") else {
            log.error("RepairWatcher: responses dir unreachable; result for \(id) dropped",
                      scope: AppLogScope.fsck)
            return
        }
        let dst = responsesURL.appendingPathComponent(
            DiskJockeyRepairFiles.resultFilename(id: id)
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(result)
            try data.write(to: dst, options: .atomic)
            log.info("RepairWatcher: wrote result \(dst.lastPathComponent) (success=\(result.success))",
                     scope: AppLogScope.fsck)
        } catch {
            log.error("RepairWatcher: cannot write result for \(id): \(error.localizedDescription)",
                      scope: AppLogScope.fsck)
        }
    }
}
