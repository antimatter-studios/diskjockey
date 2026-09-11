//
//  OperationLockTests.swift — the cooperative mutex that keeps a verify and
//  a repair off the same live mount.
//
//  WHY THIS ONE MATTERS MORE THAN ITS SIZE SUGGESTS
//  -----------------------------------------------
//  This is the whole coordination story between the two entry points that
//  can reach a mounted volume at once: `startCheck` via fsck_fskit, and
//  RepairXPCService driven from the host app. A verify reading the journal
//  while a repair writes commits is the failure it exists to prevent, and
//  the file says plainly that nothing in the OS enforces it — "the lock is
//  **cooperative**: every caller must check it". Preemptive alternatives
//  (unmount, O_EXCL, fcntl(F_SETLK)) are out, because the sandbox forbids
//  them and the architecture mounts live during fsck.
//
//  So the lock is the only thing standing between those two operations, and
//  it had no tests. In particular nothing exercised the property that makes
//  it a mutex at all: that under a race, exactly ONE caller acquires.
//
//  ONE BEHAVIOUR HERE IS A SHARP EDGE, AND IT IS TESTED AS IT IS SPECIFIED
//  rather than as it might be preferred. `release()` is documented as
//  unconditional and is implemented that way, so a caller holding nothing
//  can clear a holder's lock. That is recorded below as behaviour, not
//  asserted as correct — a test that pretended otherwise would fail against
//  the shipped code, and a test that skipped it would leave the sharpest
//  edge in the file undocumented.
//
//  Host-free: no mount, no extension, no XPC.
//

import Foundation
import Testing
@testable import DiskJockeyLibrary

@Suite("OperationLock")
struct OperationLockTests {

    @Test func aFreshLockIsIdle() {
        #expect(OperationLock().current == nil)
    }

    @Test("acquiring from idle succeeds and records the holder",
          arguments: [FsckOperation.verify, .repair])
    func acquireFromIdle(op: FsckOperation) {
        let lock = OperationLock()
        #expect(lock.tryAcquire(op) == nil, "acquiring an idle lock must succeed")
        #expect(lock.current == op)
    }

    /// THE REJECTION CARRIES THE CONFLICTING OPERATION, which is the whole
    /// reason `tryAcquire` returns an optional operation rather than a Bool:
    /// the caller surfaces it so the user is told *which* work is in flight.
    @Test func aConflictingAcquireIsRejectedAndNamesTheHolder() {
        let lock = OperationLock()
        #expect(lock.tryAcquire(.verify) == nil)
        #expect(lock.tryAcquire(.repair) == .verify,
                "a rejected acquire must name the operation holding the lock")
        #expect(lock.current == .verify,
                "a failed acquire must not overwrite the holder")
    }

    @Test func theOtherDirectionIsRejectedToo() {
        let lock = OperationLock()
        #expect(lock.tryAcquire(.repair) == nil)
        #expect(lock.tryAcquire(.verify) == .repair)
        #expect(lock.current == .repair)
    }

    /// NOT RE-ENTRANT, and that is the useful behaviour: a second verify
    /// starting while the first is still running is exactly the concurrent
    /// access this lock exists to refuse, and it would be invisible if the
    /// same operation could acquire twice.
    @Test("the same operation cannot acquire twice",
          arguments: [FsckOperation.verify, .repair])
    func notReentrant(op: FsckOperation) {
        let lock = OperationLock()
        #expect(lock.tryAcquire(op) == nil)
        #expect(lock.tryAcquire(op) == op,
                "a second \(op.rawValue) must be rejected, not silently admitted")
    }

    @Test func releaseReturnsTheLockToIdleAndItCanBeTakenAgain() {
        let lock = OperationLock()
        #expect(lock.tryAcquire(.verify) == nil)
        lock.release()
        #expect(lock.current == nil)
        #expect(lock.tryAcquire(.repair) == nil, "a released lock must be available to the other operation")
        #expect(lock.current == .repair)
    }

    @Test func releasingAnIdleLockIsHarmless() {
        let lock = OperationLock()
        lock.release()
        lock.release()
        #expect(lock.current == nil)
        #expect(lock.tryAcquire(.verify) == nil)
    }

    /// RECORDED BEHAVIOUR, NOT AN ENDORSEMENT. `release()` takes no
    /// operation and checks nothing, so whoever calls it clears whatever is
    /// held. The doc comment says to pair it with a successful `tryAcquire`
    /// via `defer`; this test says what happens when someone does not, so
    /// that the next reader finds the edge here rather than in a log.
    @Test func releaseIsUnconditionalSoANonHolderCanClearIt() {
        let lock = OperationLock()
        #expect(lock.tryAcquire(.repair) == nil)
        // A caller that never acquired anything releases:
        lock.release()
        #expect(lock.current == nil,
                "release() is documented as unconditional; if this now fails, it grew an ownership check and this test should assert that instead")
    }

    /// THE PROPERTY THAT MAKES IT A MUTEX, and the one nothing tested.
    /// Under contention exactly one caller may come away holding the lock —
    /// no matter how the tasks interleave.
    @Test func underContentionExactlyOneCallerAcquires() async {
        for _ in 0..<20 {
            let lock = OperationLock()
            let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for i in 0..<64 {
                    group.addTask {
                        lock.tryAcquire(i.isMultiple(of: 2) ? .verify : .repair) == nil
                    }
                }
                var count = 0
                for await won in group where won { count += 1 }
                return count
            }
            #expect(winners == 1, "\(winners) callers acquired the same lock")
            #expect(lock.current != nil, "the winner's hold was lost")
        }
    }

    /// And release/acquire churn under contention leaves the lock in a legal
    /// state rather than wedged — every acquire is paired, so the lock must
    /// end idle.
    @Test func pairedAcquireAndReleaseUnderContentionEndsIdle() async {
        let lock = OperationLock()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<64 {
                group.addTask {
                    let op: FsckOperation = i.isMultiple(of: 2) ? .verify : .repair
                    if lock.tryAcquire(op) == nil {
                        lock.release()
                    }
                }
            }
        }
        #expect(lock.current == nil, "every acquire was released, so the lock must be idle")
    }

    /// A REFERENCE TYPE ON PURPOSE. The class comment gives the reason:
    /// `MountedResource` is a struct, and copies of it must share one lock —
    /// if this were a value type, each copy would get its own and the mutex
    /// would coordinate nothing.
    @Test func copiesOfAHolderShareOneLock() {
        struct Resource { let lock: OperationLock }
        let original = Resource(lock: OperationLock())
        let copy = original
        #expect(original.lock.tryAcquire(.verify) == nil)
        #expect(copy.lock.current == .verify,
                "a copied holder sees its own lock; OperationLock must stay a reference type")
        #expect(copy.lock.tryAcquire(.repair) == .verify)
    }
}

@Suite("FsckOperation")
struct FsckOperationTests {

    /// The raw values reach log lines and rejection messages, so they are a
    /// surface rather than an implementation detail.
    @Test func rawValuesAreTheLoggedSpellings() {
        #expect(FsckOperation.verify.rawValue == "verify")
        #expect(FsckOperation.repair.rawValue == "repair")
        #expect(FsckOperation(rawValue: "verify") == .verify)
        #expect(FsckOperation(rawValue: "repair") == .repair)
        #expect(FsckOperation(rawValue: "Verify") == nil)
    }

    @Test func displayNamesAreDistinctAndNonEmpty() {
        let names = [FsckOperation.verify, .repair].map(\.displayName)
        #expect(names == ["verify", "repair"])
        #expect(Set(names).count == names.count)
    }
}
