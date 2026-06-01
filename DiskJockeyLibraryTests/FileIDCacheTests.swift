//
// FileIDCacheTests.swift — coverage for the generic fileID-keyed cache
// that replaced the two divergent per-volume cache implementations.
//
// The behaviours pinned here:
//
//   1. Empty cache: get-or-create on a fresh id runs the create
//      closure exactly once and returns its result.
//   2. Hit-and-validate path: a second lookup whose validator returns
//      true re-uses the cached instance (object identity check).
//   3. Hit-and-replace path: a second lookup whose validator returns
//      false runs create() again, replaces the cache entry, and
//      returns the new instance (the load-bearing failure mode that
//      kept inode reuse + hard-link aliasing + driver-reused-fileID
//      bugs from surfacing as ENOENT in Finder).
//   4. Independent keys: distinct ids get distinct entries; one
//      eviction doesn't affect the other.
//   5. `remove` evicts so the next `getOrCreate` runs create() again.
//   6. `count` reflects what was inserted / removed.
//   7. Concurrent stress: many parallel `getOrCreate` calls for the
//      same id leave the cache with exactly one live entry and don't
//      crash under TSan-like contention. (Best-effort smoke — Swift
//      doesn't run TSan in xctest by default; the OSUnfairLock
//      enforces serialised access regardless.)
//

import XCTest
@testable import DiskJockeyLibrary

/// Stand-in for `EXT4Item` / `NTFSItem` in tests — the cache only
/// requires `AnyObject`, so we avoid pulling in FSKit just for a
/// unit-test fixture.
private final class TestItem {
    let tag: String
    init(_ tag: String) { self.tag = tag }
}

final class FileIDCacheTests: XCTestCase {

    // MARK: - Single-thread behaviour

    func testGetOrCreateOnEmptyCacheRunsCreateOnce() {
        let cache = FileIDCache<TestItem>()
        var createCalls = 0

        let item = cache.getOrCreate(
            id: 1,
            validate: { _ in true },
            create: { createCalls += 1; return TestItem("a") }
        )

        XCTAssertEqual(createCalls, 1)
        XCTAssertEqual(item.tag, "a")
        XCTAssertEqual(cache.count, 1)
    }

    func testValidateTrueReturnsCachedInstance() {
        let cache = FileIDCache<TestItem>()
        let first = cache.getOrCreate(
            id: 7, validate: { _ in true }, create: { TestItem("x") }
        )

        var createCalls = 0
        let second = cache.getOrCreate(
            id: 7,
            validate: { _ in true },
            create: { createCalls += 1; return TestItem("y") }
        )

        XCTAssertEqual(createCalls, 0)
        XCTAssertTrue(first === second)
    }

    func testValidateFalseReplacesEntry() {
        let cache = FileIDCache<TestItem>()
        let first = cache.getOrCreate(
            id: 42, validate: { _ in true }, create: { TestItem("old") }
        )

        var createCalls = 0
        let second = cache.getOrCreate(
            id: 42,
            validate: { _ in false },
            create: { createCalls += 1; return TestItem("new") }
        )

        XCTAssertEqual(createCalls, 1)
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.tag, "new")
        XCTAssertEqual(cache.count, 1)
    }

    func testDistinctKeysAreIndependent() {
        let cache = FileIDCache<TestItem>()
        let a = cache.getOrCreate(id: 1, validate: { _ in true },
                                  create: { TestItem("A") })
        let b = cache.getOrCreate(id: 2, validate: { _ in true },
                                  create: { TestItem("B") })

        XCTAssertFalse(a === b)
        XCTAssertEqual(cache.count, 2)

        cache.remove(id: 1)
        XCTAssertEqual(cache.count, 1)

        let bAgain = cache.getOrCreate(
            id: 2, validate: { _ in true },
            create: { XCTFail("should not re-create"); return TestItem("?") }
        )
        XCTAssertTrue(b === bAgain)
    }

    func testRemoveEvictsAndNextGetReinstalls() {
        let cache = FileIDCache<TestItem>()
        _ = cache.getOrCreate(id: 5, validate: { _ in true },
                              create: { TestItem("first") })
        cache.remove(id: 5)
        XCTAssertEqual(cache.count, 0)

        var createCalls = 0
        let again = cache.getOrCreate(
            id: 5,
            validate: { _ in true },
            create: { createCalls += 1; return TestItem("second") }
        )
        XCTAssertEqual(createCalls, 1)
        XCTAssertEqual(again.tag, "second")
        XCTAssertEqual(cache.count, 1)
    }

    func testRemoveOnAbsentIdIsNoOp() {
        let cache = FileIDCache<TestItem>()
        cache.remove(id: 999)
        XCTAssertEqual(cache.count, 0)
    }

    // MARK: - Concurrency smoke

    func testConcurrentGetOrCreateForSameIDLeavesOneLiveEntry() {
        let cache = FileIDCache<TestItem>()
        let iterations = 200

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            _ = cache.getOrCreate(
                id: 100,
                // Half the callers approve the cached entry; the other
                // half force a replace. The lock guarantees the cache
                // ends in a consistent state with exactly one entry.
                validate: { _ in i % 2 == 0 },
                create: { TestItem("worker-\(i)") }
            )
        }

        XCTAssertEqual(cache.count, 1)
    }

    func testConcurrentDistinctIDsDoNotLoseEntries() {
        let cache = FileIDCache<TestItem>()
        let n = 500

        DispatchQueue.concurrentPerform(iterations: n) { i in
            _ = cache.getOrCreate(
                id: UInt64(i),
                validate: { _ in true },
                create: { TestItem("item-\(i)") }
            )
        }

        XCTAssertEqual(cache.count, n)
    }
}
