//
// MountableFileSystem.swift — protocols that codify the shape every
// DiskJockey FSKit extension's FSUnaryFileSystem subclass shares, plus
// the thread-safe registry that backs the mounted-resource bookkeeping.
//
// Why these exist:
//
//   • EXT4FileSystem and NTFSFileSystem each declared an identical
//     `static let mountedResources = OSAllocatedUnfairLock<
//     [ObjectIdentifier: MountedResource]>(initialState: [:])` field
//     and reimplemented the same four operations against it: register
//     on load, remove on unload, resolve-the-sole-entry for
//     startCheck/startFormat, and find-by-bsdName for the
//     RepairXPCService. Same shape, two byte-near-identical
//     implementations.
//
//   • Centralising the registry behind `MountedResourceRegistry<R>`
//     gets the storage discipline (lock primitive, key derivation
//     from `ObjectIdentifier`, single-mount disambiguation) in one
//     place. Future filesystems get the same posture for free.
//
//   • `MountedResource` documents the minimum each per-FS record must
//     expose so generic code (e.g. the registry's `first(where:)` over
//     bsdName, future cross-FS diagnostics) can rely on those fields.
//

import FSKit
import Foundation
import os

// MARK: - MountedResource

/// Minimum contract every mounted-resource record exposes. Each
/// per-FS extension keeps its own struct (which can carry additional
/// backend handles, context pointers, cfg sizes, …) and adopts this
/// protocol to make the shared fields available to generic code.
///
/// `bsdName` is the per-mount disk identifier (e.g. `disk5s1` for
/// block devices, the file URL path for FSPathURLResource mounts).
/// Carried so per-mount logging and the RepairXPCService lookup can
/// tag / find the right record.
///
/// `opLock` is the cooperative tri-state mutex coordinating verify
/// (`startCheck`) and repair (`RepairXPCService`) on this volume.
/// Default `.idle` ⇒ filesystem is available for normal operations.
/// See `OperationLock` for the full contract.
public protocol MountedResource {
    var bsdName: String { get }
    var opLock: OperationLock { get }
}

// MARK: - MountedResourceRegistry

/// Thread-safe map from FSResource identity to a `MountedResource`
/// record. Replaces the hand-rolled `OSAllocatedUnfairLock<
/// [ObjectIdentifier: Record]>` fields that each FSKit extension used
/// to declare separately.
///
/// Keyed by `ObjectIdentifier(resource)` — FSKit hands us the same
/// `FSResource` instance for the lifetime of the mount, so the
/// in-process pointer is a stable, unique handle. We don't use
/// `FSResource.identifier` (UUID) because the registry is purely
/// in-process: an out-of-process consumer would have to look up via
/// the bsdName route (`first(where:)`).
///
/// `@unchecked Sendable` because the only stored property is the lock,
/// and every read / write goes through `withLock`. Same posture as
/// `FileIDCache` — see that type for the full justification.
public final class MountedResourceRegistry<Resource: MountedResource>: @unchecked Sendable {

    private let storage = OSAllocatedUnfairLock<[ObjectIdentifier: Resource]>(initialState: [:])

    public init() {}

    /// Register `record` for `key`. Replaces any prior entry under the
    /// same `ObjectIdentifier(key)`. `key` is typed `AnyObject` rather
    /// than `FSResource` so tests can use stand-in identities; in
    /// production every caller passes an `FSResource`.
    public func register(_ key: AnyObject, _ record: Resource) {
        storage.withLock { $0[ObjectIdentifier(key)] = record }
    }

    /// Remove the record for `key`. No-op if absent.
    public func remove(_ key: AnyObject) {
        storage.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(key)) }
    }

    /// Return the single registered record. `nil` if the registry is
    /// empty OR holds more than one entry. The "exactly one mount per
    /// extension" assumption is what `startCheck` / `startFormat`
    /// rely on, since FSKit hands them no resource handle to scope
    /// the request — surfacing ambiguity here lets callers fail
    /// loudly rather than guess which mount to operate on.
    public func resolveSingle() -> Resource? {
        storage.withLock { map in
            map.count == 1 ? map.values.first : nil
        }
    }

    /// First record matching `predicate`, or `nil` if none. Used by
    /// the RepairXPCService to locate the live mount for a given
    /// bsdName when multiple may eventually coexist.
    ///
    /// `predicate` runs while the registry's `OSAllocatedUnfairLock`
    /// is held. The lock is **non-reentrant** — a predicate that
    /// calls back into this registry (`first`, `resolveSingle`,
    /// `count`, `register`, `remove`) on the same instance will
    /// deadlock. Keep predicates to plain field comparisons; same
    /// posture as `FileIDCache.getOrCreate`'s validate/create
    /// closures.
    public func first(where predicate: (Resource) -> Bool) -> Resource? {
        storage.withLock { map in
            map.values.first(where: predicate)
        }
    }

    /// Number of currently-registered records. Diagnostics only —
    /// no production code branches on this.
    public var count: Int {
        storage.withLock { $0.count }
    }
}

// MARK: - MountableFileSystem

/// Marker for a DiskJockey FSKit extension's `FSUnaryFileSystem`
/// subclass. Declares the shared mounted-resource registry handle so
/// cross-extension tooling (RepairXPCService, future diagnostics) can
/// reach the registry through a uniform surface.
///
/// Implementers pair this with `FSUnaryFileSystem, FSUnaryFileSystemOperations`
/// from FSKit — this protocol does NOT re-declare those FSKit
/// contracts; it sits alongside them.
public protocol MountableFileSystem: AnyObject {
    /// Per-FS record type. Each extension defines its own struct
    /// (e.g. `EXT4FileSystem.MountedResource`) carrying whatever
    /// backend handles + context pointers it needs.
    associatedtype Resource: MountedResource

    /// The single registry holding the live mount(s) for this
    /// extension. Static so `startCheck` / `startFormat` — both
    /// invoked without a resource handle — can route back to the
    /// right record.
    static var mountedResources: MountedResourceRegistry<Resource> { get }
}
