//
//  VolumeUnmounterTests.swift — the guard in front of DADiskUnmount.
//
//  The DA call itself needs a mounted volume and cannot run host-free; it
//  was measured by hand for #166 (DADiskUnmount unmounted an FSKit ext4
//  volume that `diskutil unmount` refused). What these tests hold is the
//  part that would be dangerous to get wrong: DADiskCreateFromVolumePath
//  resolves ANY path to the volume containing it, so an unmount of a stale
//  mount path that is now a plain directory would land on the volume that
//  directory lives on. The unmounter must refuse every path that is not a
//  mount point, and refuse it without calling DA.
//
//  Host-free: nothing is mounted or unmounted.
//

import Foundation
import Testing
@testable import DiskJockeyLibrary

@Suite("VolumeUnmounter")
struct VolumeUnmounterTests {

    private func makeTempDir() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VolumeUnmounterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    @Test func theRootIsAMountPoint() {
        #expect(VolumeUnmounter.mountPoint(of: "/") == "/")
    }

    @Test func anOrdinaryDirectoryIsNotAMountPoint() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(VolumeUnmounter.mountPoint(of: dir) == nil)
    }

    @Test func aFileIsNotAMountPoint() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = (dir as NSString).appendingPathComponent("f")
        #expect(FileManager.default.createFile(atPath: file, contents: Data()))
        #expect(VolumeUnmounter.mountPoint(of: file) == nil)
    }

    @Test func aMissingPathIsNotAMountPoint() {
        #expect(VolumeUnmounter.mountPoint(of: "/nonexistent-\(UUID().uuidString)") == nil)
    }

    /// A symlink to a mount point resolves to it, so the comparison is made
    /// on the real path rather than the spelling the caller had.
    @Test func aSymlinkToTheRootResolvesToIt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let link = (dir as NSString).appendingPathComponent("root")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/")
        #expect(VolumeUnmounter.mountPoint(of: link) == "/")
    }

    /// The refusal is synchronous: the completion has run before `unmount`
    /// returns, which is only possible if no DiskArbitration request was
    /// made (DA answers asynchronously, on its queue).
    @Test func anUnmountOfAPlainDirectoryIsRefusedBeforeDA() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        final class Box: @unchecked Sendable { var error: Error?; var called = false }
        let box = Box()
        VolumeUnmounter.unmount(mountPath: dir, force: true) { error in
            box.called = true
            box.error = error
        }
        #expect(box.called)
        let posix = try #require(box.error as? POSIXError)
        #expect(posix.code == .EINVAL)
        #expect(FileManager.default.fileExists(atPath: dir))
    }

    @Test func anUnmountOfAMissingPathIsRefusedBeforeDA() throws {
        final class Box: @unchecked Sendable { var error: Error?; var called = false }
        let box = Box()
        VolumeUnmounter.unmount(mountPath: "/Volumes/nonexistent-\(UUID().uuidString)") { error in
            box.called = true
            box.error = error
        }
        #expect(box.called)
        #expect((box.error as? POSIXError)?.code == .EINVAL)
    }
}
