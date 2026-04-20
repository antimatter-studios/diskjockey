import Combine
import Foundation
import SwiftUI

/// Represents the available sidebar items in the app.
public enum SidebarItem: Hashable {
    /// A direct-linked network mount (host app + FileProvider extension,
    /// no backend). Lives in `DirectMountRegistry`.
    case directMount(UUID)
    case addMount
    case logs
    /// In-app management UI for DiskJockey's bundled extensions (EXT4,
    /// NTFS, FileProvider). Hosts `EXAppExtensionBrowserViewController`
    /// so the user enables/disables + sees status for all DiskJockey
    /// extensions without navigating to System Settings.
    case extensions
    /// Read-only sidebar entry for a disk currently mounted by the system
    /// (e.g. an ext4 partition or image handled by our FSKit extension).
    /// No user configuration — just visibility. Identified by mount path.
    case attachedDisk(String)
}

/// Manages the state of the sidebar and navigation.
public final class SidebarModel: ObservableObject {
    @Published public var selectedItem: SidebarItem? = nil

    public init() {}
}
