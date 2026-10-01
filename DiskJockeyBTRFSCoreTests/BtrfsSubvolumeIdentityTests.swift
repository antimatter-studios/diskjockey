//
//  BtrfsSubvolumeIdentityTests.swift — the REAL BtrfsVolume, listing and
//  looking up across subvolumes (diskjockey#261).
//
//  A Btrfs inode number means something only inside one tree, and a
//  directory entry can name a whole subvolume, in which case the number it
//  carries is a TREE id (fs_btrfs.h, `is_subvolume`). The volume used to
//  hand FSKit the dirent's number raw, so:
//
//    • a subvolume was listed under its tree id — and the first subvolume
//      ever created is tree 256, the volume root's own inode;
//    • looking the subvolume up made an item with the root's identifier,
//      which FileIDCache then swapped in for the root;
//    • the same inode number in two trees was one identifier, so each
//      lookup evicted the other tree's item.
//
//  Expected values come from FSKit's contract (one identifier, one object,
//  for the life of the mount) and from fs_btrfs.h — never from the body
//  under test. The tree shape is the real one: the mounted tree's top
//  directory is inode 256 and so is every subvolume's.
//
//  Host-free: no app, no extension bundle, no Rust, no C.
//

import Foundation
import FSKit
import Testing
@testable import DiskJockeyBTRFSCore
@testable import DiskJockeyLibrary

/// A two-tree volume. The mounted tree holds `/docs` (inode 257) and a
/// subvolume entry `/snap` naming tree 256; tree 256 holds `a.txt`, also
/// inode 257. `/odd` is a directory whose stat says 256 but which no
/// listing names as a subvolume.
private final class TwoTreeDriver: ReadOnlyVolumeDriver {

    struct Node {
        var attr: ReadOnlyFileAttributes
        /// Set for a subvolume entry: the tree id its dirent carries.
        var subvolumeTree: UInt64? = nil
    }

    var nodes: [VolumePath: Node] = [:]
    var errno: Int32 = 0

    init() {
        nodes["/"] = Node(attr: attr(256, .directory))
        nodes["/docs"] = Node(attr: attr(257, .directory))
        nodes["/snap"] = Node(attr: attr(256, .directory), subvolumeTree: 256)
        nodes["/snap/a.txt"] = Node(attr: attr(257, .file))
        nodes["/odd"] = Node(attr: attr(256, .directory))
    }

    func volumeInfo() -> ReadOnlyVolumeInfo? { nil }

    func stat(_ path: VolumePath) -> ReadOnlyFileAttributes? {
        guard let n = nodes[path] else { errno = ENOENT; return nil }
        return n.attr
    }

    func walkDirectory(_ path: VolumePath,
                       _ visit: (ReadOnlyDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk {
        guard nodes[path]?.attr.fileType == .directory else {
            errno = ENOTDIR
            return .openFailed
        }
        let prefix = path == .root ? path.bytes : path.bytes + [UInt8(ascii: "/")]
        let children = nodes.keys
            .filter { key in
                key != path && key.bytes.starts(with: prefix)
                    && !key.bytes.dropFirst(prefix.count).contains(UInt8(ascii: "/"))
            }
            .sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
        for child in children {
            let n = nodes[child]!
            let entry = ReadOnlyDirectoryEntry(
                name: child.lastComponent,
                inode: n.subvolumeTree ?? n.attr.inode,
                fileType: n.attr.fileType,
                isSubvolume: n.subvolumeTree != nil)
            if !visit(entry) { return .finished }
        }
        return .finished
    }

    func read(_ path: VolumePath, at offset: UInt64,
              into buffer: UnsafeMutableRawBufferPointer) -> Int64 { 0 }

    func readlink(_ path: VolumePath, _ buffer: UnsafeMutablePointer<CChar>,
                  _ size: Int) -> Int32 { errno = EINVAL; return -1 }

    func lastErrno() -> Int32 { errno }

    func unmount() {}
}

private func attr(_ inode: UInt64, _ type: ReadOnlyFileType) -> ReadOnlyFileAttributes {
    ReadOnlyFileAttributes(inode: inode, mode: 0o755, uid: 0, gid: 0, size: 0,
                           linkCount: 1, mtime: 1_700_000_000, fileType: type)
}

private func makeVolume() -> BtrfsVolume {
    BtrfsVolume(volumeID: FSVolume.Identifier(uuid: UUID()),
                volumeName: FSFileName(string: "test"),
                driver: TwoTreeDriver(),
                contextPtr: nil,
                bsdName: "disk0s1",
                stats: IOStatsCollector(label: "test", emit: { _ in }))
}

private func listing(_ v: BtrfsVolume, _ dir: FSItem) throws -> [String: PackableDirectoryEntry] {
    var byName: [String: PackableDirectoryEntry] = [:]
    _ = try v.entries(of: try #require(dir as? BtrfsItem), after: 0, withAttributes: true) {
        byName[$0.name.string ?? ""] = $0
        return true
    }
    return byName
}

private func lookup(_ v: BtrfsVolume, _ name: String, in dir: FSItem) async throws -> FSItem {
    try await v.lookupItem(named: FSFileName(string: name), inDirectory: dir).0
}

private func fileID(_ item: FSItem) throws -> UInt64 {
    try #require(item as? BtrfsItem).id
}

@Suite("BtrfsVolume across subvolumes")
struct BtrfsSubvolumeIdentityTests {

    /// THE REPORTED DEFECT. The entry naming subvolume 256 was listed with
    /// identifier 256 — the volume root's.
    @Test func aListedSubvolumeIsNotTheVolumeRoot() throws {
        let v = makeVolume()
        let root = try v.rootItem()
        let entries = try listing(v, root)
        let snap = try #require(entries["snap"])
        #expect(snap.itemID.rawValue != (try fileID(root)))
        #expect(snap.itemType == .directory)
    }

    /// A volume with nothing crossed keeps the identifiers it always had:
    /// the mounted tree's inodes, unchanged.
    @Test func theMountedTreesEntriesKeepTheirInodes() throws {
        let v = makeVolume()
        let root = try v.rootItem()
        #expect(try fileID(root) == 256)
        #expect(try listing(v, root)["docs"]?.itemID.rawValue == 257)
    }

    /// FSKit's contract: the identifier a listing gives an entry is the
    /// identifier a lookup of that name returns.
    @Test func lookingUpASubvolumeArrivesAtTheItemItsListingNamed() async throws {
        let v = makeVolume()
        let root = try v.rootItem()
        let listed = try #require(try listing(v, root)["snap"]).itemID.rawValue
        let found = try await lookup(v, "snap", in: root)
        #expect(try fileID(found) == listed)
        #expect(found !== root)
    }

    /// Looking a subvolume up must not displace the root: the cache holds
    /// one item per identifier, and the root's is still the root.
    @Test func lookingUpASubvolumeLeavesTheRootItsOwnItem() async throws {
        let v = makeVolume()
        let root = try v.rootItem()
        _ = try await lookup(v, "snap", in: root)
        let docs = try await lookup(v, "docs", in: root)
        #expect(try #require(docs as? BtrfsItem).parentID == (try fileID(root)))
        #expect(try v.rootItem() === root)
    }

    /// Inode 257 of the mounted tree and inode 257 of subvolume 256 are two
    /// files, so two identifiers, and neither lookup evicts the other.
    @Test func theSameInodeInTwoTreesIsTwoItems() async throws {
        let v = makeVolume()
        let root = try v.rootItem()
        let docs = try await lookup(v, "docs", in: root)
        let snap = try await lookup(v, "snap", in: root)
        let file = try await lookup(v, "a.txt", in: snap)
        #expect(try fileID(docs) != (try fileID(file)))
        #expect(try await lookup(v, "docs", in: root) === docs)
        #expect(try await lookup(v, "a.txt", in: snap) === file)
    }

    /// Inside a subvolume, the listing and the lookup still agree, and
    /// the attributes name the item and its parent by the same identifiers.
    @Test func aSubvolumesChildrenAreListedAndLookedUpAlike() async throws {
        let v = makeVolume()
        let root = try v.rootItem()
        let snap = try await lookup(v, "snap", in: root)
        let entry = try #require(try listing(v, snap)["a.txt"])
        let file = try await lookup(v, "a.txt", in: snap)
        #expect(entry.itemID.rawValue == (try fileID(file)))
        let attrs = try #require(entry.attributes)
        #expect(attrs.fileID.rawValue == (try fileID(file)))
        #expect(attrs.parentID.rawValue == (try fileID(snap)))
        let own = try await v.attributes(FSItem.GetAttributesRequest(), of: file)
        #expect(own.fileID.rawValue == (try fileID(file)))
    }

    /// A child whose stat says it is a tree's top directory has crossed a
    /// boundary, and only the parent's listing says into which tree. When
    /// the listing does not name it as a subvolume there is no tree to put
    /// it in, and the only guess — the mounted tree — is the root's
    /// identifier. EIO, not a second root.
    @Test func aCrossingTheParentDoesNotListAsASubvolumeIsEIO() async throws {
        let v = makeVolume()
        let root = try v.rootItem()
        await #expect(throws: POSIXError(.EIO)) { _ = try await lookup(v, "odd", in: root) }
    }
}
