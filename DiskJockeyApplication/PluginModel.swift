import Foundation
import Combine

// Minimal plugin struct for SwiftUI
struct Plugin: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let description: String
}

enum SidebarItem: Hashable, Identifiable {
    case about
    case plugin(Plugin)
    var id: String {
        switch self {
        case .about: return "about"
        case .plugin(let plugin): return plugin.id.uuidString
        }
    }
    var displayName: String {
        switch self {
        case .about: return "About"
        case .plugin(let plugin): return plugin.name
        }
    }
}

class PluginModel: ObservableObject {
    @Published var plugins: [Plugin] = []
    @Published var selectedPlugin: Plugin?
    @Published var selectedSidebarItem: SidebarItem? = .about

    init() {
        self.plugins = [
            Plugin(name: "Sample Plugin 1", description: "A test plugin."),
            Plugin(name: "Sample Plugin 2", description: "Another test plugin.")
        ]
        self.selectedPlugin = plugins.first
        self.selectedSidebarItem = .about
    }
}

