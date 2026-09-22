//
// DetachedOperationWatchdogTests.swift — coverage for the parent-
// death watchdog used by EXT4 (and, by extension, future NTFS use)
// to exit the appex when a detached fsck/repair/format outlives the
// mount.
//
// The watchdog's production `onExpire` calls `exit(EX_TEMPFAIL)`,
// which can't run inside the test process. Tests inject a spy
// closure instead.
//

import Foundation
import Testing
@testable import DiskJockeyLibrary

/// Thread-safe mutable box for spy state captured by the watchdog's
/// `onExpire` closure (which runs on a background `DispatchQueue`).
private final class LockBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ initial: Value) { self.value = initial }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Value) { lock.lock(); defer { lock.unlock() }; value = v }
}

// SERIALISED, because every test here asserts on a timer.
// Run in parallel they starve each other, and the suite failed CI
// twice on 2026-09-11 in BOTH directions: a monitor firing when it
// should not have, then monitors not firing when they should
// (`(fired.get() -> false) == true`, `reportedDeadline -> 0.0`).
@Suite("DetachedOperationWatchdog", .serialized)
struct DetachedOperationWatchdogTests {

    // ----- Counter arithmetic -----

    @Test func pendingStartsAtZero() {
        let w = DetachedOperationWatchdog(label: "test", defaultDeadline: 1) { _, _ in }
        #expect(w.pending == 0)
    }

    @Test func enterIncrementsLeaveDecrements() {
        let w = DetachedOperationWatchdog(label: "test", defaultDeadline: 1) { _, _ in }
        w.enter(); w.enter(); w.enter()
        #expect(w.pending == 3)
        w.leave()
        #expect(w.pending == 2)
        w.leave()
        w.leave()
        #expect(w.pending == 0)
    }

    @Test func leaveClampsAtZero() {
        let w = DetachedOperationWatchdog(label: "test", defaultDeadline: 1) { _, _ in }
        w.leave()
        w.leave()
        #expect(w.pending == 0)  // doesn't underflow
    }

    // ----- Scheduler -----

    @Test func scheduleReturnsFalseAndNoFireWhenCounterIsZero() async throws {
        let fired = LockBox(false)
        let w = DetachedOperationWatchdog(label: "test", defaultDeadline: 0.4) { _, _ in
            fired.set(true)
        }
        let scheduled = w.scheduleExpiryIfNeeded()
        #expect(scheduled == false)
        // Wait long enough that, if it HAD scheduled, it would have fired.
        try await Task.sleep(nanoseconds: 1_200_000_000)  // 1.2s
        #expect(fired.get() == false)
    }

    @Test func scheduleFiresWhenCounterStaysNonZero() async throws {
        let fired = LockBox(false)
        let reportedPending = LockBox(0)
        let reportedDeadline = LockBox(0.0)
        let w = DetachedOperationWatchdog(label: "test", defaultDeadline: 0.4) { pending, deadline in
            reportedPending.set(pending)
            reportedDeadline.set(deadline)
            fired.set(true)
        }
        w.enter()
        let scheduled = w.scheduleExpiryIfNeeded()
        #expect(scheduled == true)
        // Wait past the deadline.
        try await Task.sleep(nanoseconds: 1_600_000_000)  // 1.6s
        #expect(fired.get() == true)
        #expect(reportedPending.get() == 1)
        #expect(reportedDeadline.get() == 0.4)
    }

    @Test func scheduleDoesNotFireWhenCounterDropsToZeroBeforeDeadline() async throws {
        let fired = LockBox(false)
        let w = DetachedOperationWatchdog(label: "test", defaultDeadline: 1.2) { _, _ in
            fired.set(true)
        }
        w.enter()
        let scheduled = w.scheduleExpiryIfNeeded()
        #expect(scheduled == true)
        // Op completes before deadline.
        w.leave()
        try await Task.sleep(nanoseconds: 2_000_000_000)  // 2.0s, past the 1.2s deadline
        #expect(fired.get() == false)
    }

    @Test func deadlineOverrideHonored() async throws {
        let fired = LockBox(false)
        let reportedDeadline = LockBox(0.0)
        let w = DetachedOperationWatchdog(label: "test", defaultDeadline: 100) { _, deadline in
            reportedDeadline.set(deadline)
            fired.set(true)
        }
        w.enter()
        // Override the (long) default with a short one so we don't sit
        // around for 100s.
        let scheduled = w.scheduleExpiryIfNeeded(deadline: 0.4)
        #expect(scheduled == true)
        try await Task.sleep(nanoseconds: 1_600_000_000)
        #expect(fired.get() == true)
        #expect(reportedDeadline.get() == 0.4)
    }

    @Test func multipleConcurrentSchedulesEachReChecksCounter() async throws {
        // Two schedules, both arm. Counter drops to 0 mid-flight.
        // Neither expiry should fire because both re-check the counter
        // at fire time.
        let fireCount = LockBox(0)
        let w = DetachedOperationWatchdog(label: "test", defaultDeadline: 0.8) { _, _ in
            fireCount.set(fireCount.get() + 1)
        }
        w.enter()
        w.scheduleExpiryIfNeeded()
        w.scheduleExpiryIfNeeded()  // second arm — still 1 pending
        w.leave()  // counter -> 0 before any expiry fires
        try await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(fireCount.get() == 0)
    }

    // ----- Stuck-progress monitor (Fix D) -----

    @Test func stuckMonitorDisabledByDefaultStuckDeadlineZero() async throws {
        let fired = LockBox(false)
        let w = DetachedOperationWatchdog(label: "test", defaultDeadline: 100) { _, _ in
            fired.set(true)
        }
        // stuckDeadline defaults to 0 ⇒ disabled
        w.enter()
        // No heartbeats. With Fix D off, this should NOT fire even
        // though we sit silent indefinitely (within the test window).
        try await Task.sleep(nanoseconds: 2_400_000_000)
        #expect(fired.get() == false)
    }

    @Test func stuckMonitorFiresWhenNoHeartbeatPastDeadline() async throws {
        let fired = LockBox(false)
        let reportedDeadline = LockBox(0.0)
        let w = DetachedOperationWatchdog(
            label: "test",
            defaultDeadline: 100,
            stuckDeadline: 0.8,
            stuckCheckInterval: 0.24
        ) { _, deadline in
            reportedDeadline.set(deadline)
            fired.set(true)
        }
        w.enter()
        // No heartbeat() calls. After ~0.1s the stuck-progress monitor
        // should observe `now - lastHeartbeat > stuckDeadline` and fire.
        try await Task.sleep(nanoseconds: 2_400_000_000)
        #expect(fired.get() == true)
        #expect(reportedDeadline.get() == 0.8)
    }

    @Test func stuckMonitorFiresOnceNotOncePerTick() async throws {
        // Regression: an earlier version fired `onExpire` on every
        // timer tick after the deadline. Masked in production because
        // `exit()` terminates before the next tick, but the contract
        // is one-shot — verify with a counter spy that several check
        // intervals don't accumulate fires.
        let fireCount = LockBox(0)
        let w = DetachedOperationWatchdog(
            label: "test",
            defaultDeadline: 100,
            stuckDeadline: 0.4,
            stuckCheckInterval: 0.16
        ) { _, _ in
            fireCount.set(fireCount.get() + 1)
        }
        w.enter()
        // 250 ms with 20 ms check interval = ~12 potential ticks past
        // the 50 ms deadline. Without one-shot cancellation we'd see
        // double-digit fires. With it, exactly 1.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(fireCount.get() == 1)
    }

    @Test func stuckMonitorDoesNotFireWhileHeartbeatsArrive() async throws {
        let fireCount = LockBox(0)
        let w = DetachedOperationWatchdog(
            label: "test",
            defaultDeadline: 100,
            stuckDeadline: 2.4,
            stuckCheckInterval: 0.4
        ) { _, _ in
            fireCount.set(fireCount.get() + 1)
        }
        w.enter()
        // TWO RATIOS, AND BOTH MATTER.
        //
        // Beat every 240ms against a 2.4s deadline, thirty times — so the
        // run lasts ~7.2s in total. The gap between beats is 10x the
        // deadline, which is what makes the assertion survive a loaded
        // machine; the total run is 3x the deadline, which is what gives it
        // teeth, because a build where `heartbeat()` stopped resetting the
        // clock would fire at 300ms and fail.
        //
        // It was 8 beats of 30ms against a 100ms deadline: teeth intact
        // (240ms total > 100ms) but only 3.3x of jitter tolerance, and on
        // 2026-09-11 CI it fired once. Every neighbour in this bundle that
        // floods a pipe or sleeps is competing for the same cores, so
        // `Task.sleep(30ms)` overshooting 100ms is not a remote event —
        // `docs/constellation-report-2026-08-30.md` records this suite
        // failing the same way once before.
        for _ in 0..<30 {
            w.heartbeat()
            try await Task.sleep(nanoseconds: 240_000_000)
        }
        #expect(fireCount.get() == 0)
    }

    @Test func stuckMonitorStopsAfterLeaveTransitionsCounterToZero() async throws {
        let fired = LockBox(false)
        let w = DetachedOperationWatchdog(
            label: "test",
            defaultDeadline: 100,
            stuckDeadline: 0.4,
            stuckCheckInterval: 0.16
        ) { _, _ in
            fired.set(true)
        }
        w.enter()
        w.leave()  // immediately drop counter to 0 — monitor should cancel
        // Sleep well past the stuckDeadline. If the monitor weren't
        // cancelled it would still tick and find pending==0, so
        // wouldn't fire — but more importantly: no timer should be
        // around to consume resources after `leave`.
        try await Task.sleep(nanoseconds: 1_600_000_000)
        #expect(fired.get() == false)
    }
}
