//
//  EXT4ItemCacheTests.swift — the REAL per-volume item cache.
//
//  `DiskJockeyTests/EXT4ItemCacheTests.swift` covers this with a
//  `MirrorItem` struct and a hand-written copy of the get-or-create-or-
//  replace rule. This file drives `EXT4Volume.item(forID:path:parentInode:)`
//  itself, on a real EXT4Volume with a stub backend, so the three failure
//  modes the method documents are asserted against the code that ships.
//
//  WHY IDENTITY IS THE ASSERTION. The cache exists so that the same on-disk
//  inode reached through two operations yields the same FSItem instance —
//  FSKit compares items by identity. So `===` is the property under test,
//  not equality of fields: two distinct objects with matching paths would
//  satisfy an `==` check and still break the kernel's view.
//
//  Host-free: no mount, no Rust, no launch.
//

import Foundation
import FSKit
import Testing
@testable import DiskJockeyEXT4Core
@testable import DiskJockeyLibrary

private func makeVolume() -> EXT4Volume {
    EXT4Volume(volumeID: FSVolume.Identifier(uuid: UUID()),
               volumeName: FSFileName(string: "test"),
               backend: CacheStubBackend(),
               requiresJournalReplay: false,
               stats: IOStatsCollector(label: "test", emit: { _ in }),
               opLock: OperationLock())
}

@Suite("EXT4Volume item cache")
struct EXT4ItemCacheRealTests {

    /// THE REASON THE CACHE EXISTS. Same inode, same path, same parent — the
    /// caller must get the identical object back, or FSKit sees two items
    /// for one file.
    @Test func thesameInodeReachedTwiceYieldsTheIdenticalObject() {
        let volume = makeVolume()
        let first = volume.item(forID: 42, path: "/dir/file", parentInode: 2)
        let second = volume.item(forID: 42, path: "/dir/file", parentInode: 2)
        #expect(first === second, "the cache returned a second object for one inode")
        #expect(first.inode == 42)
        #expect(first.path == "/dir/file")
        #expect(first.parentInode == 2)
    }

    @Test func differentInodesAreDifferentItems() {
        let volume = makeVolume()
        let a = volume.item(forID: 1, path: "/a", parentInode: 2)
        let b = volume.item(forID: 2, path: "/b", parentInode: 2)
        #expect(a !== b)
        #expect(a.path == "/a")
        #expect(b.path == "/b")
    }

    /// FAILURE MODE 1: inode reuse after unlink + create. Same inode number,
    /// new path. Returning the cached item means every backend call runs
    /// against the deleted path and comes back ENOENT — the file the user
    /// just created reads as missing.
    @Test func anInodeReusedAtANewPathReplacesTheCachedItem() {
        let volume = makeVolume()
        let stale = volume.item(forID: 99, path: "/old-name", parentInode: 2)
        let fresh = volume.item(forID: 99, path: "/new-name", parentInode: 2)
        #expect(stale !== fresh, "the cache handed back the item for the deleted path")
        #expect(fresh.path == "/new-name")
        // And the replacement sticks, rather than the cache flapping.
        #expect(volume.item(forID: 99, path: "/new-name", parentInode: 2) === fresh)
    }

    /// FAILURE MODE 2: hard links. One inode, two legitimate paths, both
    /// live at once. Each lookup must describe the path it was asked about.
    @Test func aHardLinksSecondPathDoesNotInheritTheFirstsItem() {
        let volume = makeVolume()
        let first = volume.item(forID: 7, path: "/link-a", parentInode: 2)
        let second = volume.item(forID: 7, path: "/link-b", parentInode: 2)
        #expect(first !== second)
        #expect(second.path == "/link-b",
                "a backend op on this item would have run against the other link's path")
    }

    /// FAILURE MODE 3: the driver reusing one inode for several dirents
    /// (rust-fs-ext4 Bug A). Same inode, same name shape, DIFFERENT parent —
    /// which is the case a path-only comparison would miss. Finder drew the
    /// rename UI on `.fseventsd` because of this.
    @Test func thesamePathUnderADifferentParentIsADifferentItem() {
        let volume = makeVolume()
        let underRoot = volume.item(forID: 500, path: "/untitled folder", parentInode: 2)
        let underDir = volume.item(forID: 500, path: "/untitled folder", parentInode: 77)
        #expect(underRoot !== underDir,
                "the cache compared only the path, so two dirents sharing an inode collided")
        #expect(underDir.parentInode == 77)
    }

    /// The root directory is the only item with a nil parent, so nil and a
    /// value must not compare equal — otherwise root and a child sharing an
    /// inode number would alias.
    @Test func aNilParentIsDistinctFromAnyRealParent() {
        let volume = makeVolume()
        let root = volume.item(forID: 2, path: "/", parentInode: nil)
        let notRoot = volume.item(forID: 2, path: "/", parentInode: 2)
        #expect(root !== notRoot, "a nil parent and a real parent must not compare equal")
        #expect(root.parentInode == nil)
        #expect(notRoot.parentInode == 2)
        // Asking with the nil context again replaces once more: the entry
        // always describes the context the caller asked about, which is the
        // whole rule. It is a fresh object, not the original `root`.
        let rootAgain = volume.item(forID: 2, path: "/", parentInode: nil)
        #expect(rootAgain.parentInode == nil)
        #expect(rootAgain !== notRoot)
    }

    /// Caches are per volume. Two volumes must not share items, or unmounting
    /// one would hand stale objects to the other.
    @Test func twoVolumesDoNotShareACache() {
        let a = makeVolume(), b = makeVolume()
        let itemA = a.item(forID: 1, path: "/same", parentInode: 2)
        let itemB = b.item(forID: 1, path: "/same", parentInode: 2)
        #expect(itemA !== itemB, "the item cache is per volume, not global")
    }

    /// The hot path is called from whatever thread FSKit is on, and the
    /// cache's own guarantee is that one inode yields one object. Under
    /// contention that has to keep holding.
    @Test func concurrentLookupsOfOneInodeAgreeOnOneObject() async {
        let volume = makeVolume()
        let objects = await withTaskGroup(of: ObjectIdentifier.self, returning: Set<ObjectIdentifier>.self) { group in
            for _ in 0..<64 {
                group.addTask { ObjectIdentifier(volume.item(forID: 5, path: "/x", parentInode: 2)) }
            }
            var seen: Set<ObjectIdentifier> = []
            for await id in group { seen.insert(id) }
            return seen
        }
        #expect(objects.count == 1, "\(objects.count) distinct objects for one inode under contention")
    }
}

/// Minimal conformer; these tests never reach the backend.
private final class CacheStubBackend: FileSystemBackend {
    func lastErrno() -> Int32 { 0 }
    func lastErrorMessage() -> String { "(stub)" }
    func volumeInfo() -> BackendVolumeInfo { unreachable() }
    func shutdown() {}
    func stat(path: String) -> BackendFileAttributes? { unreachable() }
    func readDirectory(path: String) -> [BackendDirectoryEntry]? { unreachable() }
    func readFile(path: String, offset: UInt64, length: UInt64,
                  buffer: UnsafeMutableRawPointer) -> Int64 { unreachable() }
    func readSymlink(path: String) -> String? { unreachable() }
    func createFile(path: String, mode: UInt16) -> Bool { unreachable() }
    func writeFile(path: String, data: UnsafeRawPointer, length: UInt64) -> Int64 { unreachable() }
    func pwrite(path: String, offset: UInt64,
                data: UnsafeRawPointer, length: UInt64) -> Int64 { unreachable() }
    func unlink(path: String) -> Bool { unreachable() }
    func rename(src: String, dst: String) -> Bool { unreachable() }
    func mkdir(path: String, mode: UInt16) -> Bool { unreachable() }
    func rmdir(path: String) -> Bool { unreachable() }
    func truncate(path: String, size: UInt64) -> Bool { unreachable() }
    func chmod(path: String, mode: UInt16) -> Bool { unreachable() }
    func chown(path: String, uid: UInt32?, gid: UInt32?) -> Bool { unreachable() }
    func symlink(target: String, linkpath: String) -> Bool { unreachable() }
    func link(src: String, dst: String) -> Bool { unreachable() }
    func utimens(path: String, atime: timespec?, mtime: timespec?) -> Bool { unreachable() }
    func flush() -> Bool { unreachable() }

    private func unreachable(_ function: String = #function) -> Never {
        fatalError("CacheStubBackend.\(function) was called; these tests do not reach the backend")
    }
}
