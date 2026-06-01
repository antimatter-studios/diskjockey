//
// RepairWatcher.swift — shared file-based repair-request watcher.
//
// The host app drops a JSON-encoded `RepairRequest` into
//   <App Group>/Repair/<fsType>/requests/request-<uuid>.json
// The watcher claims it (atomic rename into `processing/`), invokes
// the caller-supplied `runRepair` closure, and writes the resulting
// `RepairResult` into
//   <App Group>/Repair/<fsType>/responses/result-<uuid>.json
//
// Both DiskJockeyEXT4 and DiskJockeyNTFS previously kept a near-
// identical 200–340 line `RepairXPCService` implementing this
// scaffold. The variation between them is small and well-bounded:
//
//   1. fs-type string (used only for the `workQueue` label).
//   2. The `runRepair` closure body (EXT4 wraps backend.runFsck with
//      throttled progress callbacks; NTFS returns a stub
//      "not implemented" result).
//   3. Optional watchdog enter/exit hooks (EXT4 tracks repair runs in
//      `DetachedOperationWatchdog`; NTFS doesn't).
//
// Everything else — start-once idempotency, DispatchSource on the
// requests-dir FD, atomic-rename-as-claim, JSON decode + filename-
// UUID fallback for malformed requests, atomic result write — is
// shared verbatim.
//
// Why files instead of XPC: ExtensionKit-extension bundles silently
// ignore Info.plist `MachServices` declarations, and anonymous
// NSXPCListener + endpoint serialization (while public-API and
// documented) is unconventional enough to risk reviewer-friction
// at App Store review. Two of our own bundles communicating through
// their shared App Group container is the textbook use of App
// Groups — uncontroversial and MAS-defensible.
//

import Foundation
import os

private extension String {
    func deletingPrefix(_ p: String) -> String {
        hasPrefix(p) ? String(dropFirst(p.count)) : self
    }
    func deletingSuffix(_ s: String) -> String {
        hasSuffix(s) ? String(dropLast(s.count)) : self
    }
}

/// File-based repair-request watcher. Construct once per per-FSKit-
/// extension principal class, call `start()` once (idempotent); the
/// instance owns the DispatchSource on the requests directory for
/// the lifetime of the extension process.
///
/// `@unchecked Sendable` — every mutable property is either
/// `OSAllocatedUnfairLock`-guarded (`startedLock`) or only touched
/// inside the work queue / dispatch handlers; the caller-supplied
/// closures must themselves be `@Sendable`.
public final class RepairWatcher: @unchecked Sendable {

    public typealias RunRepair = @Sendable (RepairRequest) -> RepairResult
    public typealias VoidHook = @Sendable () -> Void

    private let requestsURL: URL
    private let processingURL: URL
    private let responsesURL: URL
    private let log: AppLog
    private let logScope: String
    private let enterOperation: VoidHook
    private let exitOperation: VoidHook
    private let runRepair: RunRepair

    private let startedLock = OSAllocatedUnfairLock(initialState: false)
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: CInt = -1
    private let workQueue: DispatchQueue

    /// - Parameters:
    ///   - requestsURL/processingURL/responsesURL: pre-resolved App
    ///     Group directories. Caller is responsible for ensuring they
    ///     exist (via `DiskJockeyRepairFiles.ensureDirectories(forFsType:)`)
    ///     before `start()` is invoked.
    ///   - workQueueLabel: the dispatch queue label — caller threads
    ///     in its fs-type identifier.
    ///   - log/logScope: the per-target logger + log scope (callers
    ///     in this codebase pass `AppLogScope.fsck`).
    ///   - enterOperation/exitOperation: optional bracket around each
    ///     handled request. EXT4 hooks these into its parent-death
    ///     watchdog so a request mid-flight when the host disappears
    ///     gets the appex respawn. NTFS leaves them as no-ops.
    ///   - runRepair: caller-supplied repair pass. Must always return
    ///     a `RepairResult` (never throw). Runs on the watcher's work
    ///     queue; safe to do synchronous fsck work inside.
    public init(requestsURL: URL,
                processingURL: URL,
                responsesURL: URL,
                workQueueLabel: String,
                log: AppLog,
                logScope: String,
                enterOperation: @escaping VoidHook = {},
                exitOperation: @escaping VoidHook = {},
                runRepair: @escaping RunRepair) {
        self.requestsURL = requestsURL
        self.processingURL = processingURL
        self.responsesURL = responsesURL
        self.log = log
        self.logScope = logScope
        self.enterOperation = enterOperation
        self.exitOperation = exitOperation
        self.runRepair = runRepair
        self.workQueue = DispatchQueue(
            label: workQueueLabel,
            qos: .userInitiated
        )
    }

    /// Bind the DispatchSource and start processing. Idempotent: the
    /// principal class's `init()` may run once per mounted volume, but
    /// only the first call binds the watcher.
    public func start() {
        let shouldStart: Bool = startedLock.withLock { started in
            if started { return false }
            started = true
            return true
        }
        guard shouldStart else { return }

        // Sweep on startup — if the extension was killed mid-flight
        // last session, requests may be in `processing/` waiting to be
        // re-tried, and there may be pending requests already in
        // `requests/` that arrived while we weren't running.
        scanAndProcess()

        // Watch the requests directory for new arrivals.
        // DispatchSource on the directory FD fires on .write events
        // when entries are added/removed — cheaper than polling and
        // reacts in milliseconds.
        let fd = open(requestsURL.path, O_EVTONLY)
        if fd < 0 {
            let errStr = String(cString: strerror(errno))
            log.error("RepairWatcher: open(\(requestsURL.path)) failed: \(errStr)",
                      scope: logScope)
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
                 scope: logScope)
    }

    /// Scan `requests/`, claim each pending file by atomic-renaming
    /// it into `processing/`, and dispatch the repair onto the work
    /// queue. Every transition is logged so the host's per-disk log
    /// strip can render the pipeline state in real time.
    private func scanAndProcess() {
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
                      scope: logScope)
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
                         scope: logScope)
            } catch {
                // Lost the race; another worker has it. Log and
                // continue so this is visible if it ever recurs.
                log.info("RepairWatcher: skipped \(src.lastPathComponent) (already claimed): \(error.localizedDescription)",
                         scope: logScope)
                continue
            }
            workQueue.async { [weak self] in
                self?.handleRequest(at: dst)
            }
        }
    }

    /// Decode the request file, invoke `runRepair`, write the result.
    /// Always cleans up the in-flight file at the end. `internal` so
    /// tests can drive the synchronous portion directly, bypassing
    /// DispatchSource + workQueue async.
    internal func handleRequest(at processingURL: URL) {
        enterOperation()
        defer {
            // Best-effort cleanup. If unlink fails the next start()
            // will see a stale processing entry and re-process;
            // idempotent on the result side because
            // `result-<uuid>.json` overwrites.
            try? FileManager.default.removeItem(at: processingURL)
            exitOperation()
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
                     scope: logScope)
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
                      scope: logScope)
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
                          scope: logScope)
            }
            return
        }

        log.info("RepairWatcher: starting repair for request id=\(request.id) bsd=\(request.bsd)",
                 scope: logScope)
        let result = runRepair(request)
        log.info("RepairWatcher: repair finished for id=\(request.id) bsd=\(request.bsd) success=\(result.success) repaired=\(result.repairedCount.map { "\($0)" } ?? "-")",
                 scope: logScope)
        writeResult(result, for: request.id)
    }

    /// Write the result file. Atomic so the host's watcher never
    /// reads a partial JSON.
    private func writeResult(_ result: RepairResult, for id: UUID) {
        let dst = responsesURL.appendingPathComponent(
            DiskJockeyRepairFiles.resultFilename(id: id)
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(result)
            try data.write(to: dst, options: .atomic)
            log.info("RepairWatcher: wrote result \(dst.lastPathComponent) (success=\(result.success))",
                     scope: logScope)
        } catch {
            log.error("RepairWatcher: cannot write result for \(id): \(error.localizedDescription)",
                      scope: logScope)
        }
    }
}
