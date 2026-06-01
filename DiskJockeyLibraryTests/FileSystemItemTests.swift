//
// FileSystemItemTests.swift — coverage for the generic FSItem subclass
// that replaced the per-FS EXT4Item / NTFSItem classes.
//
// The behaviours pinned here:
//
//   1. Generic init round-trips every stored field (id, path, parentID).
//   2. The ext4 specialisation:
//      a. Legacy `inode` / `parentInode` forwarders read back the same
//         values the new `id` / `parentID` accessors return.
//      b. Legacy `init(inode:path:parentInode:)` produces an item whose
//         generic fields match the legacy spelling.
//   3. The NTFS specialisation: same a/b as above for
//      `fileRecordNumber` / `parentRecordNumber`.
//   4. ID widths follow the tag: ext4 = UInt32, NTFS = UInt64.
//   5. The root item shape — `parentID == nil` — round-trips for both
//      specialisations, since that's the one case the volume relies on.
//
// What is NOT tested here (intentionally):
//
//   • Cross-tag mix-up (`FileSystemItem<EXT4Tag>` passed where
//     `FileSystemItem<NTFSTag>` is expected). That's a *compile-time*
//     guarantee — a runtime test can't reach it. The build itself is
//     the test for that property.
//   • `Hashable` / `Equatable` on the item type. `FSItem` doesn't
//     conform to either, and these subclasses inherit reference
//     identity — testing it would just rediscover `NSObject` semantics.
//

import XCTest
@testable import DiskJockeyLibrary

final class FileSystemItemTests: XCTestCase {

    // MARK: - Generic

    func testGenericInitRoundTripsAllFields() {
        let item = FileSystemItem<EXT4Tag>(id: 42, path: "/foo", parentID: 7)
        XCTAssertEqual(item.id, 42)
        XCTAssertEqual(item.path, "/foo")
        XCTAssertEqual(item.parentID, 7)
    }

    func testGenericInitAcceptsNilParentForRoot() {
        let item = FileSystemItem<EXT4Tag>(id: 2, path: "/", parentID: nil)
        XCTAssertNil(item.parentID)
    }

    // MARK: - EXT4 specialisation

    func testEXT4LegacyInitMatchesGenericFields() {
        let item = EXT4Item(inode: 1234, path: "/etc/passwd", parentInode: 12)
        XCTAssertEqual(item.id, 1234)
        XCTAssertEqual(item.path, "/etc/passwd")
        XCTAssertEqual(item.parentID, 12)
    }

    func testEXT4LegacyAccessorsForwardToGenericStorage() {
        let item = FileSystemItem<EXT4Tag>(id: 99, path: "/x", parentID: 1)
        XCTAssertEqual(item.inode, item.id)
        XCTAssertEqual(item.parentInode, item.parentID)
    }

    func testEXT4RootHasNilParentInode() {
        let root = EXT4Item(inode: 2, path: "/", parentInode: nil)
        XCTAssertNil(root.parentInode)
        XCTAssertNil(root.parentID)
    }

    func testEXT4IDWidthIsUInt32() {
        let item = EXT4Item(inode: UInt32.max, path: "/big", parentInode: nil)
        // Compile-time confirmation that `item.inode` is `UInt32`:
        let typed: UInt32 = item.inode
        XCTAssertEqual(typed, UInt32.max)
    }

    // MARK: - NTFS specialisation

    func testNTFSLegacyInitMatchesGenericFields() {
        let item = NTFSItem(fileRecordNumber: 5678,
                            path: "/Windows/System32",
                            parentRecordNumber: 5)
        XCTAssertEqual(item.id, 5678)
        XCTAssertEqual(item.path, "/Windows/System32")
        XCTAssertEqual(item.parentID, 5)
    }

    func testNTFSLegacyAccessorsForwardToGenericStorage() {
        let item = FileSystemItem<NTFSTag>(id: 100, path: "/y", parentID: 1)
        XCTAssertEqual(item.fileRecordNumber, item.id)
        XCTAssertEqual(item.parentRecordNumber, item.parentID)
    }

    func testNTFSRootHasNilParentRecordNumber() {
        let root = NTFSItem(fileRecordNumber: 5,
                            path: "/",
                            parentRecordNumber: nil)
        XCTAssertNil(root.parentRecordNumber)
        XCTAssertNil(root.parentID)
    }

    func testNTFSIDWidthIsUInt64() {
        let item = NTFSItem(fileRecordNumber: UInt64.max,
                            path: "/big",
                            parentRecordNumber: nil)
        // Compile-time confirmation that `item.fileRecordNumber` is `UInt64`:
        let typed: UInt64 = item.fileRecordNumber
        XCTAssertEqual(typed, UInt64.max)
    }

    // MARK: - Phantom-tag distinctness (build-time guard)

    /// Documents — at the type level — that the two specialisations
    /// are NOT type-compatible. If a future change accidentally
    /// merges them, this no longer compiles. Runtime body is a
    /// formality so the test runner reports it as a passing case.
    func testPhantomTagsAreStaticallyDistinctTypes() {
        let ext = EXT4Item(inode: 1, path: "/a", parentInode: nil)
        let ntfs = NTFSItem(fileRecordNumber: 1, path: "/a",
                            parentRecordNumber: nil)
        // The compiler treats `type(of: ext)` and `type(of: ntfs)` as
        // distinct metatypes — confirm at runtime so a future
        // refactor that collapses them shows up here too.
        XCTAssertFalse(type(of: ext) == type(of: ntfs))
    }
}
