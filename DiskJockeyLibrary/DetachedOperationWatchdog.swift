//
// DetachedOperationWatchdog.swift — tracks long-running detached ops
// (fsck / repair / format) that don't participate in FSKit's request-
// cancel chain, and schedules a hard process exit if they outlive the
// mount.
//
// Why this exists: the Rust filesystem driver's fsck/repair/format
// entry points have no cancel hook. We dispatch them onto a
// `Task.detached`, which means when the host app or the kernel-side
// FSKit connection dies, the appex stays alive draining the Task —
// burning CPU until the op completes on its own. On a debug build with
// a large or corrupt volume that can be hours, during which the
// running appex blocks `storagekitd`'s serialized probe queue and
// wedges every other StorageKit consumer on the Mac.
//
// Mechanism: a counter tracks in-flight detached ops. When the mount
// goes away (`Volume.deactivate`), the appex calls
// `scheduleExpiryIfNeeded`. If the counter is non-zero, the watchdog
// arms a timer; if the counter is still non-zero when it fires, the
// `onExpire` closure runs. Production wires `onExpire` to `exit(EX_TEMPFAIL)`
// so `storagekitd` respawns the appex cleanly. Tests pass a spy.
//
// MIT License — see LICENSE
//

import Foundation
import os

/// Bookkeeping helper for long-running detached operations that need a
/// hard timeout when the surrounding lifecycle goes away. See file
/// header for the rationale.
///
/// Instances are thread-safe and `Sendable`. The counter is guarded by
/// an `OSAllocatedUnfairLock`; the expire timer is scheduled on a
/// caller-supplied `DispatchQueue` (default: `.global(qos: .utility)`).
public final class DetachedOperationWatchdog: @unchecked Sendable {

    /// Closure invoked when the deadline elapses with the counter
    /// still non-zero. Production passes `{ _, _ in exit(EX_TEMPFAIL) }`
    /// so the process drops and `storagekitd` respawns; tests pass a
    /// spy that flips a flag.
    ///
    /// - Parameter pending: counter value at the moment of expiry —
    ///   useful for log messages.
    /// - Parameter deadline: the effective deadline that was honored
    ///   (default-or-override) — useful for log messages.
    public typealias ExpireHandler = (_ pending: Int, _ deadline: TimeInterval) -> Void

    /// Human-readable identifier used in log messages. Typically the
    /// filesystem family ("ext4", "ntfs") so multi-extension hosts can
    /// disambiguate.
    public let label: String

    /// Default deadline applied by `scheduleExpiryIfNeeded` when the
    /// caller doesn't pass an override. Override hooks exist so the
    /// App Group default `<fs>WatchdogDeadlineSeconds` can extend the
    /// window for slow-disk diagnostics without recompiling.
    public let defaultDeadline: TimeInterval

    private let onExpire: ExpireHandler
    private let counter = OSAllocatedUnfairLock<Int>(initialState: 0)

    public init(label: String,
                defaultDeadline: TimeInterval,
                onExpire: @escaping ExpireHandler) {
        self.label = label
        self.defaultDeadline = defaultDeadline
        self.onExpire = onExpire
    }

    /// Snapshot of the in-flight-op counter. Useful for log lines that
    /// want to surface the current value alongside other context.
    public var pending: Int {
        counter.withLock { $0 }
    }

    /// Increment the counter. Pair with `leave()` in a `defer` so the
    /// counter still decrements on early return / thrown error.
    public func enter() {
        counter.withLock { $0 += 1 }
    }

    /// Decrement the counter, clamped to zero. Clamping is defensive
    /// against accidental double-`leave`; the alternative (wrap to
    /// `Int.max`) would silently break the scheduler's guard.
    public func leave() {
        counter.withLock { $0 = max(0, $0 - 1) }
    }

    /// Schedule a one-shot timer that re-checks the counter at the
    /// deadline. If the counter is still non-zero when it fires, the
    /// `onExpire` closure runs.
    ///
    /// Returns `true` when a timer was actually scheduled (counter > 0
    /// at call time) — useful for callers that want to log
    /// "watchdog armed" only when one really was. Returns `false` when
    /// the counter was zero (no work in flight, nothing to watch).
    ///
    /// Multiple concurrent schedules are tolerated: each fires
    /// independently and each re-checks the counter, so a transient
    /// non-zero counter during cleanup doesn't trigger a false expiry.
    @discardableResult
    public func scheduleExpiryIfNeeded(
        deadline: TimeInterval? = nil,
        queue: DispatchQueue = .global(qos: .utility)
    ) -> Bool {
        let snapshot = pending
        guard snapshot > 0 else { return false }
        let effective = deadline ?? defaultDeadline
        queue.asyncAfter(deadline: .now() + effective) { [weak self] in
            guard let self = self else { return }
            let still = self.pending
            if still > 0 {
                self.onExpire(still, effective)
            }
        }
        return true
    }
}
