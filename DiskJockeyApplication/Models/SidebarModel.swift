import Combine
import Foundation
import SwiftUI

/// Represents the available sidebar items in the app
public enum SidebarItem: Hashable, Identifiable {
    case about
    case mounts
    case plugins
    case systemLog
    case quit
    
    public var id: String {
        switch self {
        case .about: return "about"
        case .mounts: return "mounts"
        case .plugins: return "plugins"
        case .systemLog: return "systemLog"
        case .quit: return "quit"
        }
    }
    
    var title: String {
        switch self {
        case .about: return "About"
        case .mounts: return "Mounts"
        case .plugins: return "Plugins"
        case .systemLog: return "System Log"
        case .quit: return "Quit"
        }
    }
    
    var systemImage: String {
        switch self {
        case .about: return "info.circle"
        case .mounts: return "externaldrive"
        case .plugins: return "puzzlepiece.extension"
        case .systemLog: return "terminal"
        case .quit: return "power"
        }
    }
}

/// Manages the state of the sidebar and navigation
public final class SidebarModel: ObservableObject {
    /// The currently selected sidebar item
    @Published public var selectedItem: SidebarItem = .about
    
    public init(selectedItem: SidebarItem = .plugins) {
        self.selectedItem = selectedItem
    }
}
