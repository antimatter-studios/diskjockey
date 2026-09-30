//
// BtrfsItemIdentityTests.swift — a Btrfs item's FSKit identifier names one
// object on the volume, across subvolumes (diskjockey#261).
//
// Btrfs inode numbers are per subvolume: every subvolume's top directory
// is inode 256, and so is the mounted tree's. A directory entry can also
// name a whole subvolume, and then its "inode" is a tree id. The volume
// used both numbers raw, so the listing of a subvolume entry carried a
// tree id — 256 for the first subvolume ever made, the same number as the
// volume's own root — and two subvolumes' files shared ids in the item
// cache.
//
// The numbers used below are the ones mkfs.btrfs and `btrfs subvolume
// create` produce: the mounted tree is id 5, subvolumes are numbered from
// 256, and every tree's top directory is inode 256.
//

import XCTest
@testable import DiskJockeyLibrary

final class BtrfsItemIdentityTests: XCTestCase {

    private let firstSubvolume: UInt64 = 256
    private let secondSubvolume: UInt64 = 257

    // MARK: - Listing

    /// The entry naming a subvolume is that subvolume's top directory, not
    /// an inode numbered after its tree id.
    func testAListedSubvolumeEntryIsTheSubvolumesRoot() {
        let key = BtrfsIdentity.entryKey(inDirectoryOf: .mounted,
                                         direntInode: firstSubvolume,
                                         isSubvolume: true)
        XCTAssertEqual(key, BtrfsObjectKey(tree: .subvolume(firstSubvolume),
                                           inode: BtrfsIdentity.subvolumeRootInode))
    }

    /// An ordinary entry stays in the tree of the directory that lists it.
    func testAnOrdinaryEntryBelongsToItsDirectorysTree() {
        XCTAssertEqual(
            BtrfsIdentity.entryKey(inDirectoryOf: .subvolume(firstSubvolume),
                                   direntInode: 257, isSubvolume: false),
            BtrfsObjectKey(tree: .subvolume(firstSubvolume), inode: 257))
        XCTAssertEqual(
            BtrfsIdentity.entryKey(inDirectoryOf: .mounted,
                                   direntInode: 257, isSubvolume: false),
            BtrfsObjectKey(tree: .mounted, inode: 257))
    }

    /// The first subvolume's tree id is 256, the mounted root's inode. Read
    /// raw, the entry and the volume root were one item to FSKit.
    func testTheFirstSubvolumeEntryIsNotTheVolumeRoot() throws {
        let space = BtrfsIdentifierSpace()
        let root = try space.fileID(for: BtrfsObjectKey(
            tree: .mounted, inode: BtrfsIdentity.subvolumeRootInode))
        let entry = try space.fileID(for: BtrfsIdentity.entryKey(
            inDirectoryOf: .mounted, direntInode: firstSubvolume, isSubvolume: true))
        XCTAssertNotEqual(root, entry)
    }

    // MARK: - Lookup agrees with the listing

    /// A lookup that crosses into a subvolume lands on its top directory,
    /// and must name the item the listing named for the same entry.
    func testLookupOfASubvolumeNamesWhatTheListingNamed() throws {
        let listed = BtrfsIdentity.entryKey(inDirectoryOf: .mounted,
                                            direntInode: firstSubvolume,
                                            isSubvolume: true)
        let looked = try BtrfsIdentity.lookupKey(
            inDirectoryOf: .mounted,
            statInode: BtrfsIdentity.subvolumeRootInode,
            subvolumeEntry: { self.firstSubvolume })
        XCTAssertEqual(looked, listed)
    }

    /// Where a snapshot's copy of a nested subvolume has no ROOT_REF, the
    /// kernel — and the driver — show an empty directory with inode 2.
    /// That is still the subvolume entry the listing flagged.
    func testLookupOfAnEmptySubvolumeDirectoryNamesTheListedEntry() throws {
        let listed = BtrfsIdentity.entryKey(inDirectoryOf: .subvolume(firstSubvolume),
                                            direntInode: secondSubvolume,
                                            isSubvolume: true)
        let looked = try BtrfsIdentity.lookupKey(
            inDirectoryOf: .subvolume(firstSubvolume),
            statInode: BtrfsIdentity.emptySubvolumeDirInode,
            subvolumeEntry: { self.secondSubvolume })
        XCTAssertEqual(looked, listed)
    }

    /// An ordinary lookup never scans the directory.
    func testAnOrdinaryLookupStaysInItsTreeWithoutAScan() throws {
        var scanned = false
        let key = try BtrfsIdentity.lookupKey(
            inDirectoryOf: .subvolume(firstSubvolume), statInode: 300,
            subvolumeEntry: { scanned = true; return nil })
        XCTAssertEqual(key, BtrfsObjectKey(tree: .subvolume(firstSubvolume), inode: 300))
        XCTAssertFalse(scanned)
    }

    /// Inode 256 under a directory is a subvolume's top directory, because
    /// in its own tree 256 is the root and nothing's child. If the parent
    /// does not list the name as a subvolume there is no tree to put it
    /// in, and guessing one would hand FSKit another item's identity.
    func testASubvolumeRootTheDirectoryDoesNotListIsAnError() {
        XCTAssertThrowsError(try BtrfsIdentity.lookupKey(
            inDirectoryOf: .mounted,
            statInode: BtrfsIdentity.subvolumeRootInode,
            subvolumeEntry: { nil })) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EIO)
        }
    }

    // MARK: - The identifier space

    /// A volume with no subvolumes keeps the identifiers it always had.
    func testTheMountedTreeKeepsItsInodeNumbers() throws {
        let space = BtrfsIdentifierSpace()
        for inode: UInt64 in [256, 257, 1_000_000] {
            XCTAssertEqual(try space.fileID(for: BtrfsObjectKey(tree: .mounted, inode: inode)),
                           inode)
        }
    }

    /// Every subvolume has an inode 256 and an inode 257; none of them is
    /// another's.
    func testEqualInodesInDifferentTreesAreDifferentItems() throws {
        let space = BtrfsIdentifierSpace()
        var seen: [UInt64: BtrfsObjectKey] = [:]
        for tree: BtrfsTree in [.mounted, .subvolume(firstSubvolume), .subvolume(secondSubvolume)] {
            for inode: UInt64 in [256, 257] {
                let key = BtrfsObjectKey(tree: tree, inode: inode)
                let id = try space.fileID(for: key)
                XCTAssertNil(seen[id], "\(key) and \(seen[id].map { "\($0)" } ?? "") share id \(id)")
                seen[id] = key
            }
        }
        XCTAssertEqual(seen.count, 6)
    }

    /// The same object asked for twice is the same identifier.
    func testAnIdentifierIsStableWithinAMount() throws {
        let space = BtrfsIdentifierSpace()
        let key = BtrfsObjectKey(tree: .subvolume(secondSubvolume), inode: 300)
        _ = try space.fileID(for: BtrfsObjectKey(tree: .subvolume(firstSubvolume), inode: 300))
        XCTAssertEqual(try space.fileID(for: key), try space.fileID(for: key))
    }

    /// A directory's identifier gives back its tree, which is what scopes
    /// the entries listed in it.
    func testAnIdentifierGivesBackItsTreeAndInode() throws {
        let space = BtrfsIdentifierSpace()
        for key in [BtrfsObjectKey(tree: .mounted, inode: 256),
                    BtrfsObjectKey(tree: .subvolume(firstSubvolume), inode: 256),
                    BtrfsObjectKey(tree: .subvolume(secondSubvolume), inode: 9_999)] {
            XCTAssertEqual(try space.key(forFileID: try space.fileID(for: key)), key)
        }
    }

    /// An identifier this space never issued is refused, not decoded into
    /// a tree it never saw.
    func testAnUnissuedIdentifierIsRefused() {
        let space = BtrfsIdentifierSpace()
        XCTAssertThrowsError(try space.key(forFileID: UInt64(7) << BtrfsIdentifierSpace.inodeBits))
    }

    /// An inode number too wide for the packing is refused rather than
    /// truncated into some other object's identifier.
    func testAnInodeTooWideToPackIsRefused() {
        let space = BtrfsIdentifierSpace()
        let wide = UInt64(1) << BtrfsIdentifierSpace.inodeBits
        for tree: BtrfsTree in [.mounted, .subvolume(firstSubvolume)] {
            XCTAssertThrowsError(try space.fileID(for: BtrfsObjectKey(tree: tree, inode: wide))) {
                XCTAssertEqual(($0 as? POSIXError)?.code, .EOVERFLOW)
            }
        }
    }

    // MARK: - The item cache

    /// FileIDCache keys on the identifier alone and replaces an entry whose
    /// path does not match, so two subvolumes' same-numbered files evicted
    /// each other. Keyed on the combined identifier, both stay.
    func testTwoSubvolumesFilesLiveInTheCacheTogether() throws {
        let space = BtrfsIdentifierSpace()
        let cache = FileIDCache<BtrfsItem>()
        let a = try space.fileID(for: BtrfsObjectKey(tree: .subvolume(firstSubvolume), inode: 257))
        let b = try space.fileID(for: BtrfsObjectKey(tree: .subvolume(secondSubvolume), inode: 257))
        let itemA = cache.getOrCreate(id: a, validate: { $0.path == "/a/f" },
                                      create: { BtrfsItem(fileID: a, path: "/a/f", parentFileID: nil) })
        _ = cache.getOrCreate(id: b, validate: { $0.path == "/b/f" },
                              create: { BtrfsItem(fileID: b, path: "/b/f", parentFileID: nil) })
        let again = cache.getOrCreate(id: a, validate: { $0.path == "/a/f" },
                                      create: { BtrfsItem(fileID: a, path: "/a/f", parentFileID: nil) })
        XCTAssertEqual(cache.count, 2)
        XCTAssertTrue(again === itemA, "the second subvolume's file evicted the first's")
    }
}
