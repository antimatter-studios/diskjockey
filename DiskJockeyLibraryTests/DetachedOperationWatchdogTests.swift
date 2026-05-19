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

@Suite("DetachedOperationWatchdog")
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
        let w = DetachedOperationWatchdog(label: "test", defaultDeadline: 0.05) { _, _ in
            fired.set(true)
        }
        let scheduled = w.scheduleExpiryIfNeeded()
        #expect(scheduled == false)
        // Wait long enough that, if it HAD scheduled, it would have fired.
        try await Task.sleep(nanoseconds: 150_000_000)  // 0.15s
        #expect(fired.get() == false)
    }

    @Test func scheduleFiresWhenCounterStaysNonZero() async throws {
        let fired = LockBox(false)
        let reportedPending = LockBox(0)
        let reportedDeadline = LockBox(0.0)
        let w = DetachedOperationWatchdog(label: "test", defaultDeadline: 0.05) { pending, deadline in
            reportedPending.set(pending)
            reportedDeadline.set(deadline)
            fired.set(true)
        }
        w.enter()
        let scheduled = w.scheduleExpiryIfNeeded()
        #expect(scheduled == true)
        // Wait past the deadline.
        try await Task.sleep(nanoseconds: 200_000_000)  // 0.2s
        #expect(fired.get() == true)
        #expect(reportedPending.get() == 1)
        #expect(reportedDeadline.get() == 0.05)
    }

    @Test func scheduleDoesNotFireWhenCounterDropsToZeroBeforeDeadline() async throws {
        let fired = LockBox(false)
        let w = DetachedOperationWatchdog(label: "test", defaultDeadline: 0.15) { _, _ in
            fired.set(true)
        }
        w.enter()
        let scheduled = w.scheduleExpiryIfNeeded()
        #expect(scheduled == true)
        // Op completes before deadline.
        w.leave()
        try await Task.sleep(nanoseconds: 250_000_000)  // 0.25s, past the 0.15s deadline
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
        let scheduled = w.scheduleExpiryIfNeeded(deadline: 0.05)
        #expect(scheduled == true)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(fired.get() == true)
        #expect(reportedDeadline.get() == 0.05)
    }

    @Test func multipleConcurrentSchedulesEachReChecksCounter() async throws {
        // Two schedules, both arm. Counter drops to 0 mid-flight.
        // Neither expiry should fire because both re-check the counter
        // at fire time.
        let fireCount = LockBox(0)
        let w = DetachedOperationWatchdog(label: "test", defaultDeadline: 0.1) { _, _ in
            fireCount.set(fireCount.get() + 1)
        }
        w.enter()
        w.scheduleExpiryIfNeeded()
        w.scheduleExpiryIfNeeded()  // second arm — still 1 pending
        w.leave()  // counter -> 0 before any expiry fires
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(fireCount.get() == 0)
    }
}
