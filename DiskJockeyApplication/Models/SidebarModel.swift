import Combine
import Foundation
import SwiftUI

/// Represents the available sidebar items in the app.
public enum SidebarItem: Hashable {
    /// Landing page shown when the app opens — welcome, live counts,
    /// supported-filesystem showcase, and the primary add actions.
    case home
    /// Project / version information page (vendored library versions,
    /// architecture summary, license). Pinned to the sidebar bottom.
    case about
    /// A direct-linked network mount (host app + FileProvider extension,
    /// no backend). Lives in `DirectMountRegistry`.
    case directMount(UUID)
    case logs
    /// Read-only sidebar entry for a disk currently or previously
    /// mounted by the system (e.g. an ext4 partition or image handled
    /// by our FSKit extension). Identified by `AttachedDisk.id` — a
    /// stable handle that survives mount/unmount/replug cycles when
    /// `stableIdentity` is known.
    case attachedDisk(_ diskID: String)
    /// Sidebar entry for a *raw* (unmounted / unformatted) block
    /// device — an SD card or USB stick that has no recognized
    /// filesystem yet, or a partition we'd want to (re-)format.
    /// Identified by BSD name ("disk5", "disk5s1") which the
    /// RawDisksModel uses as its primary key.
    case rawDisk(_ bsdName: String)
}

/// Manages the state of the sidebar and navigation.
public final class SidebarModel: ObservableObject {
    @Published public var selectedItem: SidebarItem?

    /// `initial` lets the caller land on Home for returning users while
    /// still deferring to the first-run setup pane (nil) when no folder
    /// has been approved yet.
    public init(initial: SidebarItem? = .home) {
        self.selectedItem = initial
    }
}
