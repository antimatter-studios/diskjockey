//
// BlockReadCache.swift — in-process read cache for FSKit block-device
// callbacks. Bounded LRU keyed on the aligned (offset, length) window
// of each read.
//
// Why this exists:
//
//   The NTFS Rust driver re-reads the boot sector and the full 128 KB
//   $UpCase table on every write path (`Ntfs::new` →
//   `read_upcase_table`). On a slow medium (SD card, USB stick, image
//   on an external drive) each bdev round-trip costs tens of
//   milliseconds — a single 36-byte metadata write ends up doing 50+
//   seconds of redundant reads. Caching those hot sectors in-process
//   keeps subsequent writes from re-fetching them every time.
//
//   EXT4 doesn't currently need this — its Rust crate keeps its own
//   in-process state across operations on the same mount, so repeated
//   metadata fetches don't reach the callback layer. The cache is
//   opt-in on `BlockDeviceContext` (constructor parameter, default nil)
//   so EXT4 doesn't pay the per-call lock + lookup cost.
//
// Invalidation:
//
//   `invalidate(rangeOffset:length:)` drops any cached entry whose
//   stored range overlaps the written range. Sectors untouched by
//   the write (boot record, $UpCase, unrelated MFT entries) stay
//   cached. The check is conservative — an exact-key match isn't
//   required because the caller's aligned-read region might straddle
//   the same bytes a previous read covered under a different
//   (offset, length) window.
//
// LRU eviction:
//
//   When `count >= maxEntries`, the LEAST-recently-accessed entry is
//   dropped on the next insert. Access order is tracked via a parallel
//   array bumped on each `lookup` hit and on each `insert`. Index
//   updates are O(n) in the worst case, but for the expected workload
//   (working set ~ a handful of hot regions, max ~512 entries) this
//   stays cheap — the lock cost dominates regardless.
//

import Foundation

public final class BlockReadCache: @unchecked Sendable {

    private struct Key: Hashable {
        let offset: Int
        let length: Int
    }

    public let maxEntries: Int

    private let lock = NSLock()
    private var entries: [Key: [UInt8]] = [:]
    /// Oldest at index 0, newest at the end. Updated on every
    /// `lookup` hit + `insert`; entries removed by `invalidate` are
    /// also pulled from here.
    private var accessOrder: [Key] = []

    /// - Parameter maxEntries: hard cap on cached entries. Reaching
    ///   the cap evicts the least-recently-accessed entry on the next
    ///   `insert`. Defaults to 512 (≈2.5 MB for a 5 KB average entry,
    ///   the figure the NTFS extension was sized for).
    public init(maxEntries: Int = 512) {
        precondition(maxEntries > 0, "BlockReadCache maxEntries must be positive")
        self.maxEntries = maxEntries
    }

    /// Look up the bytes for `(offset, length)`. On a hit, the entry
    /// moves to the most-recently-accessed end of the LRU queue.
    public func lookup(offset: Int, length: Int) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(offset: offset, length: length)
        guard let bytes = entries[key] else { return nil }
        bumpToMostRecent(key)
        return bytes
    }

    /// Insert or replace the entry for `(offset, length)`. On capacity
    /// overflow, evicts the least-recently-accessed entry first.
    public func insert(offset: Int, length: Int, bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(offset: offset, length: length)

        if entries[key] != nil {
            // Updating an existing entry — bump its access timestamp.
            entries[key] = bytes
            bumpToMostRecent(key)
            return
        }

        if entries.count >= maxEntries {
            // Evict the oldest entry to make room.
            let oldest = accessOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        entries[key] = bytes
        accessOrder.append(key)
    }

    /// Drop every entry whose stored range overlaps `[rangeOffset,
    /// rangeOffset + length)`. Sectors entirely outside that window
    /// stay cached.
    public func invalidate(rangeOffset: Int, length: Int) {
        lock.lock()
        defer { lock.unlock() }
        let writeEnd = rangeOffset + length
        // An entry is preserved iff it sits ENTIRELY outside the
        // written range. Anything else overlaps and must drop.
        let preserved = entries.filter { key, _ in
            key.offset + key.length <= rangeOffset || key.offset >= writeEnd
        }
        if preserved.count == entries.count { return }
        entries = preserved
        accessOrder.removeAll { entries[$0] == nil }
    }

    /// Drop every cached entry. Used by tests; production code drives
    /// eviction via `invalidate` and the LRU cap.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        accessOrder.removeAll()
    }

    /// Current entry count. Diagnostic / test-only — production code
    /// doesn't branch on this.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    // MARK: - Private

    /// Move `key` to the end of `accessOrder`. Caller holds `lock`.
    /// `firstIndex(of:)` is O(n) but the working set is small in
    /// practice; the NSLock contention dominates anyway.
    private func bumpToMostRecent(_ key: Key) {
        if let idx = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: idx)
        }
        accessOrder.append(key)
    }
}
