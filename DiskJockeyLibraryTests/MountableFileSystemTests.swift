//
// MountableFileSystemTests.swift — coverage for the protocols + the
// `MountedResourceRegistry` generic that replaced the duplicated
// `OSAllocatedUnfairLock<[ObjectIdentifier: MountedResource]>` fields
// in EXT4FileSystem and NTFSFileSystem.
//
// What's pinned here:
//
//   1. `MountedResourceRegistry.register` stores under
//      `ObjectIdentifier(key)`; the first-after-register lookup sees
//      the entry; `count` reflects insertions.
//   2. `register` for an already-known key replaces the record.
//   3. `remove` evicts; the second `remove` on the same key is a
//      no-op; `count` reflects removals.
//   4. `resolveSingle()` returns the sole entry when count==1, nil
//      when empty, nil when count>1 (the load-bearing
//      single-mount-per-extension contract).
//   5. `first(where:)` returns the first matching record (bsdName
//      match path the RepairXPCService uses).
//   6. Concurrent register/remove smoke test under 200 parallel ops.
//   7. A stand-in `MountableFileSystem` conformance compiles and the
//      protocol's associated-type machinery resolves through the
//      registry property — documents the contract end-to-end.
//

import XCTest
@testable import DiskJockeyLibrary

/// Stand-in MountedResource. Carries the protocol's required fields
/// plus a `payload` for test-specific assertions.
private struct TestRecord: MountedResource {
    let bsdName: String
    let opLock: OperationLock
    let payload: String
}

/// Stand-in key. The registry types its key parameter as `AnyObject`
/// so any reference type — including test stand-ins — can be used.
private final class TestKey {}

final class MountableFileSystemTests: XCTestCase {

    // MARK: - register / remove / count

    func testRegisterStoresRecordUnderObjectIdentity() {
        let registry = MountedResourceRegistry<TestRecord>()
        let key = TestKey()
        let record = TestRecord(bsdName: "disk5s1",
                                opLock: OperationLock(),
                                payload: "first")

        registry.register(key, record)

        XCTAssertEqual(registry.count, 1)
        XCTAssertEqual(registry.resolveSingle()?.payload, "first")
    }

    func testRegisterTwiceWithSameKeyReplaces() {
        let registry = MountedResourceRegistry<TestRecord>()
        let key = TestKey()
        registry.register(key, TestRecord(bsdName: "x", opLock: OperationLock(),
                                          payload: "v1"))
        registry.register(key, TestRecord(bsdName: "x", opLock: OperationLock(),
                                          payload: "v2"))

        XCTAssertEqual(registry.count, 1)
        XCTAssertEqual(registry.resolveSingle()?.payload, "v2")
    }

    func testRemoveEvictsAndIsIdempotent() {
        let registry = MountedResourceRegistry<TestRecord>()
        let key = TestKey()
        registry.register(key, TestRecord(bsdName: "x", opLock: OperationLock(),
                                          payload: "p"))
        XCTAssertEqual(registry.count, 1)

        registry.remove(key)
        XCTAssertEqual(registry.count, 0)
        XCTAssertNil(registry.resolveSingle())

        // Second remove must not crash or underflow.
        registry.remove(key)
        XCTAssertEqual(registry.count, 0)
    }

    // MARK: - resolveSingle

    func testResolveSingleReturnsNilOnEmptyRegistry() {
        let registry = MountedResourceRegistry<TestRecord>()
        XCTAssertNil(registry.resolveSingle())
    }

    func testResolveSingleReturnsNilWhenAmbiguous() {
        let registry = MountedResourceRegistry<TestRecord>()
        let a = TestKey(), b = TestKey()
        registry.register(a, TestRecord(bsdName: "disk1", opLock: OperationLock(),
                                        payload: "A"))
        registry.register(b, TestRecord(bsdName: "disk2", opLock: OperationLock(),
                                        payload: "B"))

        XCTAssertEqual(registry.count, 2)
        XCTAssertNil(registry.resolveSingle(),
                     "resolveSingle must refuse to guess when count != 1")
    }

    // MARK: - first(where:)

    func testFirstWhereLocatesByPredicate() {
        let registry = MountedResourceRegistry<TestRecord>()
        registry.register(TestKey(),
                          TestRecord(bsdName: "disk1s1",
                                     opLock: OperationLock(), payload: "first"))
        registry.register(TestKey(),
                          TestRecord(bsdName: "disk2s1",
                                     opLock: OperationLock(), payload: "second"))

        let hit = registry.first { $0.bsdName == "disk2s1" }
        XCTAssertEqual(hit?.payload, "second")

        let miss = registry.first { $0.bsdName == "disk-nonexistent" }
        XCTAssertNil(miss)
    }

    // MARK: - Concurrency smoke

    func testConcurrentRegisterAndRemoveLeavesConsistentState() {
        let registry = MountedResourceRegistry<TestRecord>()
        let keys = (0..<100).map { _ in TestKey() }

        DispatchQueue.concurrentPerform(iterations: keys.count) { i in
            registry.register(keys[i],
                              TestRecord(bsdName: "disk\(i)",
                                         opLock: OperationLock(),
                                         payload: "p\(i)"))
        }
        XCTAssertEqual(registry.count, keys.count)

        DispatchQueue.concurrentPerform(iterations: keys.count) { i in
            registry.remove(keys[i])
        }
        XCTAssertEqual(registry.count, 0)
    }

    // MARK: - MountableFileSystem associated-type machinery

    /// A standalone class that conforms to `MountableFileSystem`. The
    /// real conformances (`EXT4FileSystem`, `NTFSFileSystem`) live in
    /// their respective extension targets which the test bundle
    /// doesn't link; verifying the protocol's shape here proves the
    /// contract compiles independently. If a future refactor breaks
    /// the protocol — e.g. the associated-type / property pairing —
    /// this test stops building before the real callers do.
    private final class StandInFS: MountableFileSystem {
        typealias Resource = TestRecord
        static let mountedResources = MountedResourceRegistry<TestRecord>()
    }

    func testMountableFileSystemConformanceCompilesAndExposesRegistry() {
        let key = TestKey()
        StandInFS.mountedResources.register(
            key,
            TestRecord(bsdName: "stand-in",
                       opLock: OperationLock(),
                       payload: "ok")
        )
        defer { StandInFS.mountedResources.remove(key) }

        XCTAssertEqual(StandInFS.mountedResources.resolveSingle()?.payload, "ok")
    }
}
