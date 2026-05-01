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
    /// Read-only sidebar entry for a disk currently or previously
    /// mounted by the system (e.g. an ext4 partition or image handled
    /// by our FSKit extension). Identified by `AttachedDisk.id` — a
    /// stable handle that survives mount/unmount/replug cycles when
    /// `stableIdentity` is known.
    case attachedDisk(_ diskID: String)
}

/// Manages the state of the sidebar and navigation.
public final class SidebarModel: ObservableObject {
    @Published public var selectedItem: SidebarItem? = nil

    public init() {}
}
