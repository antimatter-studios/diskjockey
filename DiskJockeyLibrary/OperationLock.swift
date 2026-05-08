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
//
// Both extensions (EXT4, NTFS) instantiate one OperationLock per
// MountedResource. Lifetime matches the volume's mount lifetime.
//

import Foundation
import os

public enum FsckOperation: String, Sendable {
    case verify
    case repair

    /// Human-readable form for log lines and UI banners.
    public var displayName: String {
        switch self {
        case .verify: return "verify"
        case .repair: return "repair"
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

    /// Snapshot of the current holder, or nil if `.idle`. Useful for
    /// log lines and rejection messages; do NOT use for "should I
    /// acquire?" decisions — that's a TOCTOU bug, use `tryAcquire`.
    public var current: FsckOperation? {
        return lock.withLock { $0 }
    }
}
