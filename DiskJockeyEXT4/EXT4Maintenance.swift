/*
 * EXT4Maintenance.swift — `FSManageableResourceMaintenanceOperations`
 * conformance: `startCheck` (fsck) and `startFormat` (mkfs.ext4).
 *
 * Both ops resolve the live mount via `Self.mountedResources.resolveSingle()`
 * (FSKit hands these methods no resource handle), bracket the work in
 * `Self.enterOperation` / `Self.exitOperation` for the parent-death
 * watchdog, and stream NDJSON events (`fsck.start`, `fsck.progress`,
 * `fsck.done`, `fsck.failed`, `format.start`, `format.done`,
 * `format.failed`) the host's `AttachedDisksModel` consumes.
 *
 * `FsckProgressTracker` is the local helper that maps the Rust
 * crate's phase/done/total stream onto a 0-100
 * `NSProgress.completedUnitCount`. Only used by `startCheck` so it
 * lives alongside it.
 */

import FSKit
import Foundation
import os
import DiskJockeyLibrary

extension EXT4FileSystem: FSManageableResourceMaintenanceOperations {
    /// Run an ext4 fsck pass driven by the Rust crate's
    /// `fs_ext4_fsck_run`. Emits NDJSON events the host app's
    /// `AttachedDisksModel` consumes: `fsck.start`, `fsck.progress`,
    /// `fsck.done`, `fsck.failed`.
    ///
    /// We use a detached `Task` rather than running synchronously
    /// because FSKit expects `startCheck` to return a `Progress`
    /// immediately and have us call `task.didComplete(error:)` once
    /// the work is finished — exactly what NSProgress + an async tail
    /// is for.
    ///
    /// `FSManageableResourceMaintenanceOperations` does NOT pass us a
    /// resource handle (see header comment on `mountedResources`).
    /// Since `FSUnaryFileSystem` instances host one mount at a time
    /// during their lifetime, we resolve the mount by reading the
    /// single entry from `mountedResources`. If multiple are ever
    /// registered (hypothetical multi-volume FSKit future) we fail
    /// loudly rather than guess.
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        // Empty registry → caller invoked fsck before any volume was
        // loaded. Multiple entries → ambiguous (we assume one mount
        // per extension; surfacing as nil lets us refuse loudly
        // rather than guess which mount to verify).
        guard let resolved = Self.mountedResources.resolveSingle() else {
            log.error("startCheck: no (or ambiguous) mounted resource registered — refusing", scope: AppLogScope.fsck)
            throw POSIXError(.EBADF)
        }
        let bsdName = resolved.bsdName
        let backend = resolved.backend
        let opLock = resolved.opLock
        let dlog = TaggedLogger(
            log, fields: ["bsd": bsdName], kind: "ext4.fsck",
            scope: AppLogScope.fsck
        )

        // fsck_fskit validates module-option flags against the
        // extension's `FSCheckOptionSyntax` plist before forwarding,
        // so any flag we want to honour here MUST also be declared
        // there. We accept the BSD-style flags Apple's tools use:
        //   -y : repair without prompting (yes-to-all)
        //   -n : audit only, never write   (already the default)
        //   -q : quick check (currently treated as audit-only)
        // Plain argv contains/`-y` works because FSKit drops fsck_fskit's
        // canonical short options into taskOptions verbatim. The log
        // line surfaces both the raw argv and our derived intent so
        // future debugging doesn't require re-instrumenting.
        let argv = options.taskOptions
        let repairRequested = argv.contains("-y")

        // Cooperative tri-state mutex. Reject up front if the volume
        // is already being verified or repaired. The matching release
        // sits inside the Task.detached closure below so the lock
        // tracks the actual operation lifetime, not just this scope.
        let acquireOp: FsckOperation = repairRequested ? .repair : .verify
        if let busy = opLock.tryAcquire(acquireOp) {
            dlog.warn("startCheck rejected: volume busy with \(busy.displayName)")
            throw POSIXError(.EBUSY)
        }

        dlog.info("startCheck: bsd=\(bsdName) taskOptions=\(argv) repair=\(repairRequested)")
        dlog.event(kind: "fsck.start", fields: [
            "repair": repairRequested ? "true" : "false",
        ])

        // Pin Progress at 100 total units; the tracker bumps
        // `completedUnitCount` per phase as the Rust crate reports.
        // The Rust fsck has no cancel hook, so we don't wire a
        // `cancellationHandler` — partition cancel from FSKit's UI
        // would be best-effort no-op.
        let progress = Progress(totalUnitCount: 100)

        // "directory" dominates because that's where the Rust crate
        // walks every entry and reports `done`/`total` against that
        // workload — see `FsckProgressTracker` for the full slicing.
        let tracker = FsckProgressTracker()

        // Throttle fsck.progress emission. The Rust crate calls
        // onProgress once per directory walked + once per inode batch
        // — on a multi-thousand-dir volume that's thousands of
        // callbacks per second. Each emit lands on the host's main
        // actor (LogTailService → applyExtensionEvent → SwiftUI
        // rerender), so unthrottled emission floods the runloop and
        // beachballs the UI. NSProgress.completedUnitCount is updated
        // every callback (cheap KVO write), so the FSKit-side progress
        // bar stays smooth — only the structured event going to the
        // host is rate-limited. Mirror of the throttle in
        // RepairXPCService.
        let appGroupDefaults = UserDefaults(suiteName: AppLog.groupIdentifier)
        let verbose = appGroupDefaults?.bool(forKey: "verboseRepairLog") ?? false
        let minIntervalNs: UInt64 = verbose ? 100_000_000 : 1_000_000_000  // 10 Hz vs 1 Hz
        var lastEmitMonotonic: UInt64 = 0
        var lastPhase: String = ""

        // Detached so the closure isn't tied to any actor; the C
        // callbacks fire on Rust's worker thread anyway. The opLock
        // release happens here (not at the throw point) because the
        // operation continues asynchronously.
        //
        // Wrapped with `enter/exitOperation` so the parent-death
        // watchdog (see `scheduleWatchdogIfNeeded`) knows fsck is
        // still in flight if the mount tears down mid-pass.
        Self.enterOperation()
        Task.detached {
            defer {
                opLock.release()
                Self.exitOperation()
            }
            let result = backend.runFsck(
                repair: repairRequested,
                onProgress: { phase, done, total in
                    // Stuck-progress heartbeat. Tells the watchdog
                    // the op is still alive — must be unthrottled
                    // (called on every Rust progress callback) so a
                    // long quiet phase doesn't accidentally trip
                    // `stuckDeadline`.
                    Self.watchdog.heartbeat()
                    // Throttle. Phase change always emits (so the user
                    // sees the pipeline advance) and the first emit
                    // bypasses the time gate (so the progress bar
                    // appears immediately). All other emits are gated
                    // to the throttle interval.
                    let now = monotonicNanos()
                    let phaseChanged = phase != lastPhase
                    let intervalElapsed = lastEmitMonotonic == 0
                        || (now &- lastEmitMonotonic) >= minIntervalNs
                    if phaseChanged || intervalElapsed {
                        lastEmitMonotonic = now
                        lastPhase = phase
                        dlog.event(kind: "fsck.progress", fields: [
                            "phase": phase,
                            "done":  "\(done)",
                            "total": "\(total)",
                        ])
                    }
                    // Compute and apply progress. NSProgress is
                    // thread-safe for `completedUnitCount` writes;
                    // KVO observers receive notifications on the
                    // posting thread, which UI code on the host side
                    // hops to the main queue itself. We update this
                    // unconditionally — it's an atomic int64 write,
                    // not a UI rerender, so it doesn't contribute to
                    // the main-actor flood.
                    let units = tracker.observe(
                        phase: phase, done: done, total: total)
                    progress.completedUnitCount = units
                },
                onFinding: { f in
                    // Findings are noisy diagnostic detail — surface
                    // them as plain WARN log lines so they appear in
                    // the partition log strip, not the fsck status
                    // pill.
                    dlog.warn("fsck finding: kind=\(f.kind) inode=\(f.inode) \(f.detail)")
                }
            )

            switch result {
            case .success(let report):
                dlog.event(kind: "fsck.done", fields: report.toEventFields())
                progress.completedUnitCount = 100
                task.didComplete(error: nil)

            case .failure(let err):
                dlog.event(kind: "fsck.failed", fields: [
                    "error": "\(err)",
                ])
                task.didComplete(error: err)
            }
        }

        return progress
    }

    /// Start formatting the resource as ext4. Mirror of `startCheck`
    /// in shape: FSKit hands us a task + argv-style options but **no
    /// FSResource** (see `FSManageableResourceMaintenanceOperations`
    /// in the macOS 26 SDK headers). Same `mountedResources` map
    /// trick — find the single loaded device and operate on its
    /// `BlockDeviceContext`.
    ///
    /// **Current limitations** — captured in detail at
    /// `docs/fskit-format-pipeline.md`:
    /// 1. Disk MUST be loaded via `loadResource` first, otherwise we
    ///    throw `ENOTSUP`. Blank/raw disks (no recognized FS) never
    ///    load, so this path can't format them yet.
    /// 2. Formatting an actively-mounted volume corrupts the kernel
    ///    buffer cache. Caller is expected to unmount first; we don't
    ///    enforce it because the extension can't drive `diskutil` from
    ///    its sandbox.
    /// 3. The host-app side (`RawDiskDetailView`) is responsible for
    ///    the pre-format unmount + admin prompt + re-probe dance.
    ///
    /// The Rust `fs_ext4_mkfs` itself works correctly — round-trip
    /// tested, fsck.ext4 in CI confirms output is valid. The unsafe
    /// part is the *integration* with a live macOS mount, not the
    /// bytes we write.
    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        // Same single-mount-per-extension assumption as startCheck —
        // surface ambiguity loudly rather than guessing.
        guard let resolved = Self.mountedResources.resolveSingle() else {
            log.error(
                "startFormat: no loaded resource to format — disk must be probed/loaded first; see docs/fskit-format-pipeline.md",
                scope: AppLogScope.fsck
            )
            throw POSIXError(.ENOTSUP)
        }
        guard let resolvedContextPtr = resolved.contextPtr else {
            log.error("startFormat: not supported for file-backed mounts", scope: AppLogScope.fsck)
            throw POSIXError(.ENOTSUP)
        }
        let bsdName = resolved.bsdName
        let dlog = TaggedLogger(
            log, fields: ["bsd": bsdName], kind: "ext4.format",
            scope: AppLogScope.fsck
        )
        dlog.info("startFormat \(bsdName): taskOptions=\(options.taskOptions)")

        // Parse the `-L <label>` option if present in argv. We accept
        // it positionally because newfs_fskit forwards the user's CLI
        // args verbatim. No declared `FSFormatOptionSyntax` yet (would
        // be ideal — Apple's intended way) so we hand-parse.
        var label: String? = nil
        let argv = options.taskOptions
        if let idx = argv.firstIndex(of: "-L"), idx + 1 < argv.count {
            label = argv[idx + 1]
        }

        let progress = Progress(totalUnitCount: 100)
        dlog.event(kind: "format.start", fields: [
            "label": label ?? "",
        ])

        // Track in the parent-death watchdog counter — same rationale
        // as fsck. mkfs runs entirely inside the Rust crate with no
        // cancel hook, so if the mount goes away mid-format we want
        // the watchdog to exit the appex once the deadline elapses.
        Self.enterOperation()
        Task.detached {
            defer { Self.exitOperation() }
            // Build a fresh blockdev cfg pointing at the same
            // BlockDeviceContext the live mount is using. The cfg's
            // read/write/flush callbacks dispatch through the same C
            // shim as the mount path — so writes go through FSKit's
            // FSBlockDeviceResource just like a normal file write
            // would. Safety caveat: if the volume is mounted, the
            // kernel buffer cache is now stale. Unmount-after-format
            // is the user's responsibility (see doc).
            let bdc = resolvedContextPtr
            var cfg = fs_ext4_blockdev_cfg_t()
            cfg.read = { ctx, buf, offset, length in
                guard let ctx = ctx, let buf = buf else { return EIO }
                let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                return context.read(into: buf, offset: off_t(offset), length: Int(length))
            }
            cfg.write = { ctx, buf, offset, length in
                guard let ctx = ctx, let buf = buf else { return EIO }
                let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                return context.write(from: buf, offset: off_t(offset), length: Int(length))
            }
            cfg.flush = { ctx in
                guard let ctx = ctx else { return EIO }
                let context = Unmanaged<BlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
                return context.flush()
            }
            cfg.context = bdc
            // Pull size + block_size from the BlockDeviceContext's
            // resource; same values the original cfg used at load.
            let context = Unmanaged<BlockDeviceContext>.fromOpaque(bdc).takeUnretainedValue()
            cfg.size_bytes = UInt64(context.resource.blockCount * context.resource.blockSize)
            cfg.block_size = UInt32(context.resource.blockSize)

            // Convert label to a C string. Truncate to 16 bytes (ext4
            // superblock max). nil-safe — fs_ext4_mkfs accepts NULL.
            let labelCString = label?.cString(using: .utf8)
            let rc = labelCString?.withUnsafeBufferPointer { cbuf in
                fs_ext4_mkfs(&cfg, cbuf.baseAddress, nil)
            } ?? fs_ext4_mkfs(&cfg, nil, nil)

            if rc == 0 {
                dlog.event(kind: "format.done", fields: [:])
                progress.completedUnitCount = 100
                task.didComplete(error: nil)
            } else {
                let err = fs_ext4_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
                dlog.event(kind: "format.failed", fields: ["error": err], level: .error)
                task.didComplete(error: POSIXError(.EIO))
            }
        }

        return progress
    }
}

/// Maps the Rust crate's phase/done/total stream onto a 0-100
/// `NSProgress.completedUnitCount`. Each known phase contributes a
/// fixed slice; unknown phase names contribute zero. Phase changes
/// are monotonic (the Rust crate completes phases in order), so once
/// a new phase appears we credit the full weight of all prior ones
/// regardless of intra-phase progress.
///
/// Lock guards the mutable cursor so callbacks fired from the Rust
/// thread are serialised against any future caller. We use
/// `OSAllocatedUnfairLock` for consistency with the rest of this
/// extension; the critical section is purely arithmetic.
final class FsckProgressTracker: @unchecked Sendable {
    private struct State {
        var lastPhase: String = ""
        var completedFloor: Int64 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    private static let totalUnits: Int64 = 100
    private static let phaseWeight: [String: Int64] = [
        "superblock": 5,
        "journal":    10,
        "directory":  60,
        "inodes":     20,
        "finalize":   5,
    ]

    func observe(phase: String, done: UInt64, total: UInt64) -> Int64 {
        return state.withLock { s -> Int64 in
            if phase != s.lastPhase {
                if !s.lastPhase.isEmpty {
                    s.completedFloor += Self.phaseWeight[s.lastPhase] ?? 0
                }
                s.lastPhase = phase
            }
            let weight = Self.phaseWeight[phase] ?? 0
            let intra: Int64
            if total == 0 {
                intra = 0
            } else {
                let ratio = max(0.0, min(1.0, Double(done) / Double(total)))
                intra = Int64(Double(weight) * ratio)
            }
            return min(Self.totalUnits, s.completedFloor + intra)
        }
    }
}
