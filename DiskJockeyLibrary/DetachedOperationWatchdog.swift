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

    /// Maximum gap allowed between `heartbeat()` calls while any op
    /// is pending. When `> 0`, a background timer wakes once per
    /// `stuckCheckInterval` seconds and fires `onExpire` if the gap
    /// has exceeded this deadline. `0` disables the stuck-progress
    /// monitor entirely — the watchdog then behaves identically to
    /// pre-Fix-D (only the `scheduleExpiryIfNeeded` deactivate-side
    /// trigger fires).
    public let stuckDeadline: TimeInterval

    /// How often the background stuck-progress timer wakes to check
    /// `now - lastHeartbeat`. Tighter than `stuckDeadline` so the
    /// effective fire latency is at most one tick past the deadline.
    public let stuckCheckInterval: TimeInterval

    private let onExpire: ExpireHandler
    private let counter = OSAllocatedUnfairLock<Int>(initialState: 0)
    private let lastHeartbeatNs = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private let stuckTimer = OSAllocatedUnfairLock<DispatchSourceTimer?>(initialState: nil)

    public init(label: String,
                defaultDeadline: TimeInterval,
                stuckDeadline: TimeInterval = 0,
                stuckCheckInterval: TimeInterval = 1.0,
                onExpire: @escaping ExpireHandler) {
        self.label = label
        self.defaultDeadline = defaultDeadline
        self.stuckDeadline = stuckDeadline
        self.stuckCheckInterval = stuckCheckInterval
        self.onExpire = onExpire
    }

    /// Snapshot of the in-flight-op counter. Useful for log lines that
    /// want to surface the current value alongside other context.
    public var pending: Int {
        counter.withLock { $0 }
    }

    /// Increment the counter. Pair with `leave()` in a `defer` so the
    /// counter still decrements on early return / thrown error.
    ///
    /// When `stuckDeadline > 0` and this transitions the counter
    /// from 0 → 1, the stuck-progress monitor arms — a background
    /// timer that fires `onExpire` if `heartbeat()` hasn't been
    /// called for longer than `stuckDeadline` while ops are pending.
    public func enter() {
        let became1 = counter.withLock { c -> Bool in
            c += 1
            return c == 1
        }
        // Reset the heartbeat clock on first entry so a slow-to-start
        // op gets a full `stuckDeadline` window before being judged
        // stuck. Subsequent `enter()` calls don't disturb the clock —
        // an in-flight op's heartbeat protection shouldn't be reset
        // by a sibling op starting up.
        if became1 && stuckDeadline > 0 {
            lastHeartbeatNs.withLock { $0 = monotonicNanos() }
            armStuckTimer()
        }
    }

    /// Decrement the counter, clamped to zero. Clamping is defensive
    /// against accidental double-`leave`; the alternative (wrap to
    /// `Int.max`) would silently break the scheduler's guard.
    ///
    /// When this transitions the counter from 1 → 0, the
    /// stuck-progress monitor is cancelled.
    public func leave() {
        let became0 = counter.withLock { c -> Bool in
            c = max(0, c - 1)
            return c == 0
        }
        if became0 {
            cancelStuckTimer()
        }
    }

    /// Refresh the "last heartbeat" timestamp. Detached ops should
    /// call this from their `onProgress` (or equivalent) callback so
    /// the stuck-progress monitor knows the op is still making
    /// forward progress. Safe to call from any thread.
    ///
    /// No-op when `stuckDeadline == 0` (Fix D disabled).
    public func heartbeat() {
        guard stuckDeadline > 0 else { return }
        lastHeartbeatNs.withLock { $0 = monotonicNanos() }
    }

    // MARK: - Stuck-progress monitor (Fix D)

    private func armStuckTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let intervalNs = UInt64(stuckCheckInterval * 1_000_000_000)
        timer.schedule(
            deadline: .now() + stuckCheckInterval,
            repeating: .nanoseconds(Int(intervalNs))
        )
        timer.setEventHandler { [weak self] in self?.stuckTick() }
        stuckTimer.withLock { $0 = timer }
        timer.resume()
    }

    private func cancelStuckTimer() {
        stuckTimer.withLock { current in
            current?.cancel()
            current = nil
        }
    }

    private func stuckTick() {
        let pending = self.pending
        guard pending > 0 else { return }
        let last = lastHeartbeatNs.withLock { $0 }
        guard last > 0 else { return }
        let elapsedNs = monotonicNanos() &- last
        let deadlineNs = UInt64(stuckDeadline * 1_000_000_000)
        guard elapsedNs >= deadlineNs else { return }
        // One-shot fire. Cancel the timer BEFORE invoking onExpire
        // so subsequent ticks can't re-enter — `lastHeartbeatNs` is
        // never refreshed here, so without this cancel every
        // following tick would also satisfy the deadline guard and
        // re-call onExpire. In production that's masked because
        // onExpire calls `exit()` and the process is gone before
        // the next tick lands, but the contract should be explicit
        // and robust against an onExpire that doesn't terminate
        // (e.g. test spies that just flip a counter).
        cancelStuckTimer()
        onExpire(pending, stuckDeadline)
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
