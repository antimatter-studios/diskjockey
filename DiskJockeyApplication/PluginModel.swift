import Foundation
import Combine

// Minimal plugin struct for SwiftUI
struct Plugin: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let description: String
}



class PluginModel: ObservableObject {
    @Published var plugins: [Plugin] = []
    
    init() {
        self.plugins = [
            Plugin(name: "Sample Plugin 1", description: "A test plugin."),
            Plugin(name: "Sample Plugin 2", description: "Another test plugin.")
        ]
    }
}

