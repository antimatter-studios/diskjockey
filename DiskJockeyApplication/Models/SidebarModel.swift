import Combine
import Foundation
import SwiftUI

/// Represents the available sidebar items in the app.
///
/// Design note: we use a SEPARATE `directMount(UUID)` case rather than
/// reusing `mount(UUID)`, because backend-routed mounts and direct
/// mounts live in different repositories (`MountRepository` vs
/// `DirectMountRegistry`) and the detail view needs to route on source.
/// Unifying the cases would force a runtime lookup in both stores on
/// every sidebar interaction, which is fiddlier than just tagging the
/// case. Keep them distinct.
public enum SidebarItem: Hashable {
    case mount(UUID)
    /// Direct-linked mount (host app + FileProvider extension, no
    /// backend). Shown in the sidebar the same way as a backend mount.
    case directMount(UUID)
    case addMount
    case logs
    /// Read-only sidebar entry for a disk currently mounted by the system
    /// (e.g. an ext4 partition or image handled by our FSKit extension).
    /// No user configuration — just visibility. Identified by mount path.
    case attachedDisk(String)
}

/// Manages the state of the sidebar and navigation
public final class SidebarModel: ObservableObject {
    /// The currently selected sidebar item
    @Published public var selectedItem: SidebarItem? = nil

    public init() {}
}
