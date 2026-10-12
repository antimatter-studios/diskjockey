//
//  ShippedFilesystems.swift — the filesystems the app ships an FSKit
//  extension for, in one list.
//
//  Every place that names them reads this list: the partition probe's
//  classification behind Add Disk Image, extension enable-state, and the
//  Home page's Filesystems card. Each used to restate its own, and the
//  copies drifted: XFS and Btrfs shipped and mounted through DiskArbitration
//  while Add Disk Image skipped them as "no driver" (diskjockey#351) and the
//  Home page left them out (diskjockey#346). A new extension is one entry
//  here.
//

import Foundation

/// One filesystem the app ships an FSKit extension for.
public struct ShippedFilesystem: Sendable, Equatable {
    /// The extension's key: the last component of its bundle identifier,
    /// and the filesystem type its volumes are mounted under.
    public let key: String
    /// The name a person reads.
    public let displayName: String
    /// The `fs_kind` names the partition probes (the app's own and
    /// blk.probe) give a filesystem this extension mounts.
    public let probeKinds: Set<String>

    public init(key: String, displayName: String, probeKinds: Set<String>) {
        self.key = key
        self.displayName = displayName
        self.probeKinds = probeKinds
    }
}

public enum ShippedFilesystems {
    /// In the order the app lists them.
    public static let all: [ShippedFilesystem] = [
        ShippedFilesystem(key: "ext4", displayName: "ext4", probeKinds: ["ext4", "ext3", "ext2"]),
        ShippedFilesystem(key: "ntfs", displayName: "NTFS", probeKinds: ["ntfs"]),
        ShippedFilesystem(key: "xfs", displayName: "XFS", probeKinds: ["xfs"]),
        ShippedFilesystem(key: "btrfs", displayName: "Btrfs", probeKinds: ["btrfs"]),
        ShippedFilesystem(key: "erofs", displayName: "EROFS", probeKinds: ["erofs"]),
        ShippedFilesystem(key: "squashfs", displayName: "SquashFS", probeKinds: ["squashfs"]),
    ]

    /// Every extension key, in order.
    public static var keys: [String] { all.map(\.key) }

    /// Every probe name one of the extensions mounts.
    public static var probeKinds: Set<String> {
        all.reduce(into: Set<String>()) { $0.formUnion($1.probeKinds) }
    }

    /// The extension that mounts a filesystem a probe named `fsKind`, or
    /// nil when the app ships none.
    public static func extensionKey(forProbeKind fsKind: String) -> String? {
        all.first { $0.probeKinds.contains(fsKind) }?.key
    }
}
