import Combine
import Foundation
import SwiftUI

/// Represents the available sidebar items in the app
public enum SidebarItem: Hashable {
    case mount(UUID)
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
