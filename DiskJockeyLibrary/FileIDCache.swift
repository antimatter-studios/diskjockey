//
// FileIDCache.swift — thread-safe map from FSKit fileID to a reference-
// typed item, with caller-supplied validation on hit.
//
// Why this exists:
//
//   • Both EXT4Volume and NTFSVolume kept a `[UInt64: Item]` dictionary
//     guarded by a lock, with the same get-or-create-or-replace shape
//     (look the fileID up, return the cached item iff a per-FS sanity
//     check still passes, otherwise build + store a new item). EXT4
//     used `OSAllocatedUnfairLock`; NTFS used `NSLock` — two
//     implementations of the same invariant diverging on lock
//     primitive alone.
//
//   • The validation step is load-bearing: every backend op is
//     path-based, so a stale cached item whose `path` no longer
//     matches the kernel's current lookup yields ENOENT against the
//     wrong path. Concrete failure modes that motivated the original
//     check (kept here for posterity since this cache now hides them
//     behind a closure):
//
//       1. Inode / record reuse after `unlink` + `create` — same id,
//          new path.
//       2. Hard-linked files reachable via two different paths —
//          lookup of the second path returned the item cached for
//          the first.
//       3. Driver bug: rust-fs-ext4 mkdir reusing the same inode
//          across dirents made every `untitled folder N` resolve to
//          the FSItem cached for `.fseventsd` first, with Finder
//          drawing rename UI on the wrong row.
//
// The validation predicate is supplied by the caller so the cache
// itself stays oblivious to per-FS rules — ext4 compares `path` and
// `parentInode`, NTFS compares `path` and `parentRecordNumber`, and a
// future flavour can compare whatever it needs to.
//

import Foundation
import os

/// Thread-safe cache keyed on the FSKit `fileID` integer (always
/// `UInt64` regardless of the filesystem's native identity width).
/// `Item` is a reference type so cached entries can be handed back to
/// FSKit without copying.
///
/// `OSAllocatedUnfairLock` rather than `NSLock` for two reasons: it's
/// the modern Sendable-correct primitive, and holding it across an
/// `await` is a compile-time error — matching the invariant the volume
/// code already relies on (never block FSKit's queue waiting on this
/// lock during async I/O).
public final class FileIDCache<Item: AnyObject> {

    private let storage = OSAllocatedUnfairLock<[UInt64: Item]>(initialState: [:])

    public init() {}

    /// Returns the cached item for `id` if one exists AND `validate`
    /// approves it; otherwise calls `create` (under the lock) and
    /// installs / returns the new item, evicting any prior entry for
    /// the same id.
    ///
    /// Both closures run while the lock is held — the validate path
    /// is read-only, but `create` must NOT call back into this cache
    /// or perform any blocking I/O (per the unfair-lock contract).
    public func getOrCreate(id: UInt64,
                            validate: (Item) -> Bool,
                            create: () -> Item) -> Item {
        storage.withLock { items in
            if let existing = items[id], validate(existing) {
                return existing
            }
            let newItem = create()
            items[id] = newItem
            return newItem
        }
    }

    /// Evict the entry for `id` if present. No-op otherwise. Called
    /// from FSKit's `reclaimItem` so the cache doesn't outlive the
    /// kernel's interest in the item.
    public func remove(id: UInt64) {
        storage.withLock { items in
            _ = items.removeValue(forKey: id)
        }
    }

    /// Number of currently-cached items. Intended for tests and
    /// diagnostics — the volume code never branches on this.
    public var count: Int {
        storage.withLock { $0.count }
    }
}
