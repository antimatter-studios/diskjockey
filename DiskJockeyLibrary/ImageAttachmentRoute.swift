//
// ImageAttachmentRoute.swift — how a disk image becomes a block device.
//
// hdiutil attaches raw, VHD and VMDK images itself. It does not read qcow2
// or VHDX, so those go to the DriverKit virtual disk, which serves their
// blocks through the Rust image readers in the agent. Anything else has no
// route and is refused rather than handed to a tool that would misread it.
//
// The container names are the ones the partition probe reports.
//

import Foundation

public enum ImageAttachmentRoute: Equatable, Sendable {
    case hdiutil
    case driverKit
    case unsupported

    public init(container: String) {
        switch container.lowercased() {
        case "raw", "vhd", "vmdk": self = .hdiutil
        case "qcow2", "vhdx":      self = .driverKit
        default:                   self = .unsupported
        }
    }

    /// Whether Apple's filesystems (FAT, exFAT, HFS+, APFS) can mount from
    /// this route. They need a kernel block device: hdiutil provides one,
    /// and so does the agent's owned DriverKit attachment (diskjockey#486).
    public var reachesAppleFilesystems: Bool {
        self != .unsupported
    }

    /// Whether every partition on this route mounts read-only. The DriverKit
    /// virtual disk serves its blocks read-only (diskjockey#479).
    public var mountsReadOnly: Bool {
        self == .driverKit
    }

    /// The Disk Arbitration mount type for an Apple filesystem the probe
    /// reports, or nil when the kind is not one or this route cannot reach it.
    public func appleMountType(forProbeKind kind: String) -> String? {
        guard reachesAppleFilesystems else { return nil }
        switch kind {
        case "fat32", "fat16": return "msdos"
        case "exfat":          return "exfat"
        case "hfs_plus":       return "hfs"
        case "apfs":           return "apfs"
        default:               return nil
        }
    }

    /// The mount type for a partition the probe reports: DiskJockey's own
    /// FSKit extension key, else Apple's mount type, else nil (skipped).
    public func mountType(forProbeKind kind: String) -> String? {
        ShippedFilesystems.extensionKey(forProbeKind: kind) ?? appleMountType(forProbeKind: kind)
    }
}

/// What the disk-image inspector offers below the partition list: mount
/// controls for any container with an attachment route, qcow2 and VHDX
/// included, with or without a partition table (a bare filesystem mounts
/// its whole disk, diskjockey#515), or a notice for an image it cannot attach.
public enum DiskImageInspectorMountState: Equatable, Sendable {
    case mountControls
    /// No attachment route for this container at all.
    case unsupportedContainer

    public init(container: String) {
        switch ImageAttachmentRoute(container: container) {
        case .unsupported: self = .unsupportedContainer
        case .hdiutil, .driverKit: self = .mountControls
        }
    }
}
