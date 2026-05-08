//
//  EXT4ItemCacheTests.swift — regression tests for the EXT4Volume item
//  cache's path/parent validation.
//
//  THE BUG THIS GUARDS AGAINST
//  ---------------------------
//  EXT4Volume keeps a `[fileID: EXT4Item]` cache so the same on-disk
//  inode reached via two operations gets the same FSItem instance.
//  Originally the cache returned the first-stored entry on any hit,
//  ignoring the lookup context's `path` / `parentInode`. This blew up
//  in three ways:
//
//    1. Inode reuse after delete + create — stat against the cached
//       (now-stale) path returns ENOENT, so the new file appears
//       missing.
//    2. Hard-linked files — second path lookup returned the FSItem
//       built for the first, so backend ops ran against the wrong
//       path string.
//    3. rust-fs-ext4 mkdir corruption — when the driver reuses the
//       same inode for several dirents (a separate Rust-side bug),
//       every new folder collapsed into the FSItem cached for an
//       earlier name (most visibly `.fseventsd`). Finder rendered
//       the rename UI on `.fseventsd` whenever the user clicked
//       "New Folder."
//
//  The fix: on cache hit, validate `path` and `parentInode`. Mismatch
//  → evict, build a fresh EXT4Item, store it. The driver might still
//  be corrupt, but at least the FSKit shim stops compounding it by
//  handing the same FSItem to two unrelated dirents.
//
//  Same mirror approach as EXT4VolumeTests / EXT4AttributeMaskTests:
//  this bundle can't import the EXT4 extension target, so the cache
//  is reproduced in-test. If you change `EXT4Volume.item(forID:…)`,
//  update `MirrorCache.lookupOrInsert` below to match.
//

import Foundation
import Testing

// MARK: - Mirror

/// Stands in for `EXT4Item` — only the fields the cache validates.
private struct MirrorItem: Equatable {
    let inode: UInt32
    let path: String
    let parentInode: UInt32?
}

/// Mirror of `EXT4Volume.item(forID:path:parentInode:)`.
///
/// IMPORTANT: keep aligned with the production implementation in
/// `DiskJockeyEXT4/EXT4Volume.swift`. The cache invariant under test:
/// hit only when fileID + path + parentInode all match.
private final class MirrorCache {
    private var items: [UInt64: MirrorItem] = [:]
    /// Records every (fileID, path) pair this cache produced a fresh
    /// MirrorItem for. Lets tests assert "this lookup actually evicted
    /// vs reused" without exposing internal state.
    private(set) var freshConstructionsAtCallSite: [String] = []

    func lookupOrInsert(fileID: UInt64,
                        path: String,
                        parentInode: UInt32?) -> MirrorItem {
        if let existing = items[fileID],
           existing.path == path,
           existing.parentInode == parentInode {
            return existing
        }
        let fresh = MirrorItem(
            inode: UInt32(fileID), path: path, parentInode: parentInode)
        items[fileID] = fresh
        freshConstructionsAtCallSite.append("\(fileID)@\(path)")
        return fresh
    }

    func evict(fileID: UInt64) {
        items.removeValue(forKey: fileID)
    }
}

// MARK: - Tests

struct EXT4ItemCacheTests {

    @Test func samePathAndParentReuseCachedItem() throws {
        let cache = MirrorCache()
        let a = cache.lookupOrInsert(fileID: 100, path: "/foo", parentInode: 2)
        let b = cache.lookupOrInsert(fileID: 100, path: "/foo", parentInode: 2)
        #expect(a == b)
        // Only one fresh construction recorded — second lookup was a hit.
        #expect(cache.freshConstructionsAtCallSite.count == 1)
    }

    /// The headline regression: lookup with a different path on the
    /// same fileID must NOT return the previously-cached item, otherwise
    /// every backend op on the new lookup runs against the stale path.
    @Test func differentPathSameFileIDReturnsFreshItem() throws {
        let cache = MirrorCache()
        let stale = cache.lookupOrInsert(
            fileID: 79521, path: "/.fseventsd", parentInode: 2)
        let fresh = cache.lookupOrInsert(
            fileID: 79521, path: "/home/pi/untitled folder 2", parentInode: 909)
        #expect(stale.path == "/.fseventsd")
        #expect(fresh.path == "/home/pi/untitled folder 2")
        #expect(stale != fresh,
                "Cache returned the .fseventsd entry for the new folder lookup — Finder will draw the rename UI on .fseventsd")
        #expect(fresh.parentInode == 909,
                "fresh item must carry the new parent inode, not the stale .fseventsd one")
    }

    /// Same fileID, same path, but different parent inode — should
    /// also force a fresh item. Parent inode reuse can happen on its
    /// own (e.g. an inode recycled into a different directory) and
    /// would silently mis-attribute parentID in the FSItem.Attributes
    /// reply.
    @Test func differentParentSamePathReturnsFreshItem() throws {
        let cache = MirrorCache()
        _ = cache.lookupOrInsert(fileID: 50, path: "/x", parentInode: 2)
        let updated = cache.lookupOrInsert(fileID: 50, path: "/x", parentInode: 7)
        #expect(updated.parentInode == 7)
        #expect(cache.freshConstructionsAtCallSite.count == 2)
    }

    /// Inode-reuse-after-unlink scenario. Driver allocates inode N,
    /// caller deletes the file at /a/old, driver later reuses inode N
    /// for /b/new. Without the path check, the lookup for /b/new would
    /// return the EXT4Item still pointing at /a/old, and `attributes()`
    /// would stat /a/old — ENOENT — and Finder would think /b/new
    /// vanished.
    @Test func inodeReuseAfterUnlinkProducesFreshItem() throws {
        let cache = MirrorCache()
        let old = cache.lookupOrInsert(fileID: 1024, path: "/a/old", parentInode: 2)
        // Caller would normally evict on unlink; simulate the case
        // where it didn't (defensive — the cache must self-correct).
        let new = cache.lookupOrInsert(fileID: 1024, path: "/b/new", parentInode: 5)
        #expect(old.path == "/a/old")
        #expect(new.path == "/b/new")
        #expect(new.parentInode == 5)
    }

    /// Defensive: explicit eviction (modelling EXT4Volume.reclaimItem)
    /// followed by fresh lookup must not see the evicted item.
    @Test func evictThenLookupBuildsFreshItem() throws {
        let cache = MirrorCache()
        let original = cache.lookupOrInsert(fileID: 7, path: "/p", parentInode: 2)
        cache.evict(fileID: 7)
        let after = cache.lookupOrInsert(fileID: 7, path: "/p", parentInode: 2)
        #expect(original.path == after.path)
        // Two fresh constructions: one before evict, one after.
        #expect(cache.freshConstructionsAtCallSite.count == 2)
    }

    /// Reproduces the `untitled folder N → .fseventsd` Finder bug
    /// observed in production: every lookup against a recycled
    /// inode that the on-disk filesystem has put under multiple
    /// dirents must produce a distinct EXT4Item per (fileID, path).
    @Test func ext4DriverDuplicateDirentBugDoesNotConfuseFinder() throws {
        let cache = MirrorCache()
        // The driver cached this one first (system created `.fseventsd`).
        let fseventsd = cache.lookupOrInsert(
            fileID: 79521, path: "/.fseventsd", parentInode: 2)
        // Three subsequent "New Folder" actions, all of which the
        // (buggy) ext4 driver returned with the same inode 79521.
        let folder2 = cache.lookupOrInsert(
            fileID: 79521, path: "/home/pi/untitled folder 2", parentInode: 909)
        let folder3 = cache.lookupOrInsert(
            fileID: 79521, path: "/home/pi/untitled folder 3", parentInode: 909)
        let folder4 = cache.lookupOrInsert(
            fileID: 79521, path: "/home/pi/untitled folder 4", parentInode: 909)
        // Each folder lookup must produce a distinct path on its own
        // EXT4Item, even though the ext4 driver served them all the
        // same inode. We can't fix the on-disk corruption from here,
        // but we MUST stop FSKit from drawing the rename UI on
        // `.fseventsd` whenever the user clicks "New Folder."
        #expect(fseventsd.path != folder2.path)
        #expect(folder2.path != folder3.path)
        #expect(folder3.path != folder4.path)
        #expect(Set([fseventsd.path, folder2.path, folder3.path, folder4.path]).count == 4)
    }
}
