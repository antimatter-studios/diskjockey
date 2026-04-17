import Combine
import Foundation
import SwiftUI

/// Represents the available sidebar items in the app
public enum SidebarItem: Hashable {
    case mount(UUID)
    case addMount
    case logs
}

/// Manages the state of the sidebar and navigation
public final class SidebarModel: ObservableObject {
    /// The currently selected sidebar item
    @Published public var selectedItem: SidebarItem? = nil

    public init() {}
}
