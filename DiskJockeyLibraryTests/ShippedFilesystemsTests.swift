//
//  ShippedFilesystemsTests.swift — the one list of filesystems the app
//  ships, held to the extensions in the repository (diskjockey#346, #351).
//

import Foundation
import Testing
@testable import DiskJockeyLibrary

/// The repository root, from this file's own path.
private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()

/// Every FSKit personality the repository's extensions declare, read from
/// their Info.plist files rather than from anything the list says.
private func declaredPersonalities() throws -> Set<String> {
    var names = Set<String>()
    let dirs = try FileManager.default.contentsOfDirectory(atPath: repositoryRoot.path)
        .filter { $0.hasPrefix("DiskJockey") }
    for dir in dirs {
        let plist = repositoryRoot.appendingPathComponent(dir).appendingPathComponent("Info.plist")
        guard let data = FileManager.default.contents(atPath: plist.path),
              let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let attrs = root["EXAppExtensionAttributes"] as? [String: Any],
              attrs["EXExtensionPointIdentifier"] as? String == "com.apple.fskit.fsmodule",
              let personalities = attrs["FSPersonalities"] as? [String: Any] else { continue }
        names.formUnion(personalities.keys)
    }
    return names
}

@Suite("The filesystems the app ships")
struct ShippedFilesystemsTests {

    /// A new extension that is not in the list is an extension Add Disk
    /// Image skips and the Home page leaves out.
    @Test func theListIsEveryFSKitExtensionInTheRepository() throws {
        let declared = try declaredPersonalities()
        #expect(declared.count >= 6, "found only \(declared.sorted())")
        #expect(Set(ShippedFilesystems.keys) == declared)
    }

    /// blk.probe and the app's own probe name XFS and Btrfs `xfs` and
    /// `btrfs`; a partition either names is mounted, not skipped (#351).
    @Test(arguments: [("xfs", "xfs"), ("btrfs", "btrfs"), ("bcachefs", "bcachefs"),
                      ("ext3", "ext4"), ("ext2", "ext4"),
                      ("ntfs", "ntfs"), ("erofs", "erofs"), ("squashfs", "squashfs")])
    func aProbeNameIsMountedByItsExtension(_ kind: String, _ key: String) {
        #expect(ShippedFilesystems.extensionKey(forProbeKind: kind) == key)
    }

    @Test(arguments: ["fat32", "exfat", "hfs_plus", "apfs", "linux_swap", "unknown"])
    func aFilesystemTheAppShipsNoExtensionForHasNone(_ kind: String) {
        #expect(ShippedFilesystems.extensionKey(forProbeKind: kind) == nil)
    }

    /// The Home page's card lists them by name (#346).
    @Test func everyFilesystemHasAName() {
        #expect(ShippedFilesystems.all.map(\.displayName) == ["ext4", "NTFS", "XFS", "Btrfs", "bcachefs", "EROFS", "SquashFS"])
    }
}
