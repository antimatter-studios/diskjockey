//
// BlockReadCacheTests.swift — coverage for the offset-keyed LRU read
// cache lifted out of `NTFSBlockDeviceContext` and into
// DiskJockeyLibrary as a public type usable by any FS extension.
//
// The behaviours pinned here are the load-bearing ones from the
// original NTFS implementation, plus the LRU upgrade introduced
// during the lift:
//
//   1. Empty-cache lookup → nil.
//   2. Insert-then-lookup → returns the same bytes.
//   3. Re-insert on the same key replaces the bytes.
//   4. Distinct keys are independent.
//   5. Range-overlap invalidation drops the right entries and leaves
//      the others — this is what makes NTFS write correctness work
//      (overlapping bytes must be re-fetched; untouched ranges stay
//      cached so subsequent reads of $UpCase don't refetch).
//   6. LRU eviction at the max-entries cap: the
//      least-recently-accessed entry drops on the next insert.
//   7. `lookup` is itself a recency bump — a recently-looked-up
//      entry doesn't get evicted in favour of a newer one.
//   8. Concurrent stress: many parallel inserts + lookups +
//      invalidations don't crash and leave a consistent count.
//

import XCTest
@testable import DiskJockeyLibrary

final class BlockReadCacheTests: XCTestCase {

    // MARK: - Single-thread behaviour

    func testLookupOnEmptyCacheReturnsNil() {
        let cache = BlockReadCache()
        XCTAssertNil(cache.lookup(offset: 0, length: 512))
        XCTAssertEqual(cache.count, 0)
    }

    func testInsertAndLookupRoundTrips() {
        let cache = BlockReadCache()
        let bytes: [UInt8] = [0x55, 0xAA, 0xDE, 0xAD]
        cache.insert(offset: 4096, length: 4, bytes: bytes)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.lookup(offset: 4096, length: 4), bytes)
    }

    func testReinsertOnSameKeyReplacesBytes() {
        let cache = BlockReadCache()
        cache.insert(offset: 0, length: 4, bytes: [0x01, 0x02, 0x03, 0x04])
        cache.insert(offset: 0, length: 4, bytes: [0xFF, 0xFE, 0xFD, 0xFC])
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.lookup(offset: 0, length: 4),
                       [0xFF, 0xFE, 0xFD, 0xFC])
    }

    func testDistinctKeysAreIndependent() {
        let cache = BlockReadCache()
        cache.insert(offset: 0,    length: 4, bytes: [0xA1])
        cache.insert(offset: 512,  length: 4, bytes: [0xA2])
        cache.insert(offset: 1024, length: 8, bytes: [0xA3])
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache.lookup(offset: 0,    length: 4), [0xA1])
        XCTAssertEqual(cache.lookup(offset: 512,  length: 4), [0xA2])
        XCTAssertEqual(cache.lookup(offset: 1024, length: 8), [0xA3])
        // A near-miss on the offset returns nil — keys are by exact
        // (offset, length) tuple.
        XCTAssertNil(cache.lookup(offset: 4,    length: 4))
        XCTAssertNil(cache.lookup(offset: 0,    length: 8))
    }

    // MARK: - Range-overlap invalidation (load-bearing for NTFS)

    func testInvalidateDropsOverlappingEntries() {
        let cache = BlockReadCache()
        // Three entries: low (0..512), mid (1024..2048), high (4096..4608).
        cache.insert(offset: 0,    length: 512,  bytes: [0xA1])
        cache.insert(offset: 1024, length: 1024, bytes: [0xA2])
        cache.insert(offset: 4096, length: 512,  bytes: [0xA3])
        XCTAssertEqual(cache.count, 3)

        // Invalidate [1500..1700) — overlaps only the mid entry.
        cache.invalidate(rangeOffset: 1500, length: 200)
        XCTAssertEqual(cache.count, 2)
        XCTAssertNotNil(cache.lookup(offset: 0,    length: 512))
        XCTAssertNil   (cache.lookup(offset: 1024, length: 1024))
        XCTAssertNotNil(cache.lookup(offset: 4096, length: 512))
    }

    func testInvalidateKeepsEntriesEntirelyOutsideRange() {
        let cache = BlockReadCache()
        // Entry covers [100..200).
        cache.insert(offset: 100, length: 100, bytes: [0xA1])
        // Invalidate ranges that don't touch [100..200).
        cache.invalidate(rangeOffset: 0,   length: 100)  // ends right at 100 — no overlap
        cache.invalidate(rangeOffset: 200, length: 100)  // starts right at 200 — no overlap
        XCTAssertEqual(cache.count, 1)
        XCTAssertNotNil(cache.lookup(offset: 100, length: 100))
    }

    func testInvalidateAcrossAllDropsEverything() {
        let cache = BlockReadCache()
        cache.insert(offset: 0,    length: 100, bytes: [0xA1])
        cache.insert(offset: 200,  length: 100, bytes: [0xA2])
        cache.insert(offset: 1000, length: 100, bytes: [0xA3])
        cache.invalidate(rangeOffset: 0, length: 10_000)
        XCTAssertEqual(cache.count, 0)
    }

    // MARK: - LRU eviction

    func testLRUEvictsLeastRecentlyInsertedAtCapacity() {
        let cache = BlockReadCache(maxEntries: 3)
        cache.insert(offset: 0,    length: 4, bytes: [0xA1])
        cache.insert(offset: 100,  length: 4, bytes: [0xA2])
        cache.insert(offset: 200,  length: 4, bytes: [0xA3])
        // Cache is full; inserting a 4th drops the oldest (offset 0).
        cache.insert(offset: 300,  length: 4, bytes: [0xA4])
        XCTAssertEqual(cache.count, 3)
        XCTAssertNil   (cache.lookup(offset: 0,   length: 4))
        XCTAssertNotNil(cache.lookup(offset: 100, length: 4))
        XCTAssertNotNil(cache.lookup(offset: 200, length: 4))
        XCTAssertNotNil(cache.lookup(offset: 300, length: 4))
    }

    func testLookupBumpsRecency() {
        let cache = BlockReadCache(maxEntries: 3)
        cache.insert(offset: 0,   length: 4, bytes: [0xA1])
        cache.insert(offset: 100, length: 4, bytes: [0xA2])
        cache.insert(offset: 200, length: 4, bytes: [0xA3])
        // Touch the oldest (offset 0) — it should NOT be the next
        // victim. The least-recently-touched is now offset 100.
        _ = cache.lookup(offset: 0, length: 4)
        cache.insert(offset: 300, length: 4, bytes: [0xA4])
        XCTAssertEqual(cache.count, 3)
        XCTAssertNotNil(cache.lookup(offset: 0,   length: 4),
                        "lookup should have bumped offset=0 out of LRU victim slot")
        XCTAssertNil   (cache.lookup(offset: 100, length: 4),
                        "offset=100 was now the least-recently-accessed and should evict")
        XCTAssertNotNil(cache.lookup(offset: 200, length: 4))
        XCTAssertNotNil(cache.lookup(offset: 300, length: 4))
    }

    func testReinsertBumpsRecency() {
        let cache = BlockReadCache(maxEntries: 3)
        cache.insert(offset: 0,   length: 4, bytes: [0xA1])
        cache.insert(offset: 100, length: 4, bytes: [0xA2])
        cache.insert(offset: 200, length: 4, bytes: [0xA3])
        // Re-insert offset=0 with new bytes. It must become most-
        // recent rather than stay the oldest.
        cache.insert(offset: 0, length: 4, bytes: [0xFF])
        cache.insert(offset: 300, length: 4, bytes: [0xA4])
        XCTAssertEqual(cache.count, 3)
        XCTAssertNotNil(cache.lookup(offset: 0,   length: 4),
                        "re-insert should have bumped offset=0 out of LRU victim slot")
        XCTAssertNil   (cache.lookup(offset: 100, length: 4))
    }

    // MARK: - removeAll

    func testRemoveAllDropsEverything() {
        let cache = BlockReadCache()
        cache.insert(offset: 0,   length: 4, bytes: [0xA1])
        cache.insert(offset: 100, length: 4, bytes: [0xA2])
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.lookup(offset: 0,   length: 4))
        XCTAssertNil(cache.lookup(offset: 100, length: 4))
    }

    // MARK: - Concurrency smoke

    func testConcurrentInsertsLookupsAndInvalidationsLeaveConsistentState() {
        let cache = BlockReadCache(maxEntries: 200)

        // Phase 1: parallel inserts at distinct offsets.
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            cache.insert(offset: i * 1024, length: 512, bytes: [UInt8(i & 0xFF)])
        }
        XCTAssertEqual(cache.count, 200)

        // Phase 2: parallel lookups (recency bumps) + an
        // unconditional invalidation thread that walks through and
        // drops half of them.
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            if i.isMultiple(of: 2) {
                _ = cache.lookup(offset: i * 1024, length: 512)
            } else {
                cache.invalidate(rangeOffset: i * 1024, length: 512)
            }
        }
        // After invalidation of every odd index, 100 entries should
        // remain. Race-free because each `invalidate` only drops the
        // entries whose stored range overlaps the requested window —
        // a thread racing a lookup with an invalidate may see either
        // the entry or nil, but the count of survivors is determined
        // by which keys were invalidated, not by ordering.
        XCTAssertEqual(cache.count, 100)
    }
}
