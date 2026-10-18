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
    /// this route. They need a kernel block device; only hdiutil provides
    /// one until the app attaches DriverKit images (diskjockey#479).
    public var reachesAppleFilesystems: Bool {
        self == .hdiutil
    }
}
