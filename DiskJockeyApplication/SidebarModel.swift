import Foundation
import SwiftUI

enum SidebarItem: Hashable, Identifiable {
    case about
    case mounts
    case plugins
    case quit
    var id: String {
        switch self {
        case .about: return "about"
        case .mounts: return "mounts"
        case .plugins: return "plugins"
        case .quit: return "quit"
        }
    }
    var displayName: String {
        switch self {
        case .about: return "About"
        case .mounts: return "Mounts"
        case .plugins: return "Plugins"
        case .quit: return "Quit"
        }
    }
}

class SidebarModel: ObservableObject {
    @Published var items: [SidebarItem] = [.about, .mounts, .plugins, .quit]
    @Published var selectedItem: SidebarItem? = .about
}

