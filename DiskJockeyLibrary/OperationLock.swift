//
// OperationLock.swift — cooperative tri-state mutex coordinating
// verify / repair / normal-FS access on a single mounted volume.
//
// Two of our entry points (`FSManageableResourceMaintenanceOperations
// .startCheck` reachable via `fsck_fskit`, and `RepairXPCService` driven
// by file-based IPC from the host app) can both reach into a live mount
// concurrently. Their work is incompatible: a verify-in-progress reading
// the journal while a repair-in-progress writes commits would produce
// confused log timelines and, in pathological cases, racy reads.
//
// The lock is **cooperative**: every caller must check it. Nothing in
// the OS prevents bypass. That's deliberate — preemptive alternatives
// (unmount/remount, `O_EXCL` on the block device, `fcntl(F_SETLK)`) are
// incompatible with the MAS sandbox and with our live-mount-during-fsck
// architecture. Internal call sites are under our control, so the
// cooperative contract is enforceable by code review.
//
// Three states:
//   .idle      — the filesystem is available for normal operations.
//                Default state; either operation may transition out.
//   .verifying — a read-only audit (`fsck_fskit -t … <dev>`) is in
//                flight. Repair attempts are rejected with EBUSY.
//   .repairing — a journaled repair pass (`RepairXPCService`) is in
//                flight. Verify attempts are rejected with EBUSY.
//   .quickCheck — the read-only `-q` check the system runs while
//                mounting. Excludes a verify or repair like the others.
//
// Both extensions (EXT4, NTFS) instantiate one OperationLock per
// MountedResource. Lifetime matches the volume's mount lifetime.
//

import Foundation
import os

public enum FsckOperation: String, Sendable {
    case verify
    case repair
    /// The quick check (`-q`) the system runs as part of mounting a
    /// volume: `diskutil mount` reaches the module as `startCheck` with
    /// `taskOptions == ["-q"]` between `loadResource` and the volume's
    /// first operations (diskjockey#166). It is the BSD `fsck -q`
    /// convention — "was this volume unmounted cleanly?" — and it is
    /// read-only.
    case quickCheck

    /// Human-readable form for log lines and UI banners.
    public var displayName: String {
        switch self {
        case .verify: return "verify"
        case .repair: return "repair"
        case .quickCheck: return "quick check"
        }
    }

    /// The operation a `startCheck` call asks for, from the flags FSKit
    /// forwards in `FSTaskOptions.taskOptions` (the module's
    /// `FSCheckOptionSyntax` is `nqy`):
    ///   -y : repair            → `.repair`, whatever else is present,
    ///                            because it writes
    ///   -q : the mount's quick → `.quickCheck`
    ///        check
    ///   otherwise (-n, none)   → `.verify`, the audit a person asked for
    public init(checkOptions argv: [String]) {
        if argv.contains("-y") {
            self = .repair
        } else if argv.contains("-q") {
            self = .quickCheck
        } else {
            self = .verify
        }
    }

    /// Whether the volume answers its own operations EBUSY while this
    /// operation holds the lock (the "quiesce" in `EXT4Volume.ensureIdle`).
    ///
    /// The quick check does not: the operations that reach the volume
    /// while it runs are the mount's own, and refusing them fails the
    /// mount (diskjockey#166). They wait on the backend's lock instead.
    public var quiescesVolume: Bool {
        switch self {
        case .verify, .repair: return true
        case .quickCheck: return false
        }
    }
}

/// Tri-state mutex around fsck-class operations. Reference type so
/// `MountedResource` (a struct) can hold one and have copies of the
/// struct share the same lock instance.
public final class OperationLock: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<FsckOperation?>(initialState: nil)

    public init() {}

    /// Try to acquire the lock for `op`. Returns `nil` on success
    /// (state transitioned `.idle` → op). On failure, returns the
    /// operation currently holding the lock — the caller should
    /// surface that as an EBUSY-style rejection so the user knows
    /// which conflicting work is in flight.
    public func tryAcquire(_ op: FsckOperation) -> FsckOperation? {
        return lock.withLock { current in
            if let current = current {
                return current
            }
            current = op
            return nil
        }
    }

    /// Release the lock unconditionally. Pair with every successful
    /// `tryAcquire` (typically via `defer` or inside a `Task.detached`
    /// closure that owns the operation lifecycle).
    public func release() {
        lock.withLock { $0 = nil }
    }

    /// End the operation holding this lock, then report that it ended.
    ///
    /// `report` is where a maintenance task calls
    /// `FSTask.didComplete(error:)`. The order between the two is the
    /// contract: once FSKit is told a check has completed it goes on to
    /// mount, and the kernel's first operations on the volume may arrive
    /// immediately. Every one of them that finds the lock still held is
    /// refused EBUSY.
    public func finish(reporting report: () -> Void) {
        release()
        report()
    }

    /// Snapshot of the current holder, or nil if `.idle`. Useful for
    /// log lines and rejection messages; do NOT use for "should I
    /// acquire?" decisions — that's a TOCTOU bug, use `tryAcquire`.
    public var current: FsckOperation? {
        return lock.withLock { $0 }
    }
}
