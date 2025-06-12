import SwiftUI
import Foundation

@main
struct SwiftUIPluginListApp: App {
    @StateObject var pluginModel = PluginModel()
    @StateObject var backendManager = BackendManager()
    // Keep menu bar controller alive
    @State private var menuBarController: MenuBarController? = nil

    // Remove observer registration from init to avoid 'mutating self' capture
    // We'll register observers in .onAppear using a static helper
    static var observersRegistered = false
    static func registerObservers(pluginModel: PluginModel) {
        guard !observersRegistered else { return }
        func focusMainWindow() {
            // Open the custom URL scheme to request the main window
            if let url = URL(string: "myapp://main") {
                NSWorkspace.shared.open(url)
            }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("ShowSettingsPage"), object: nil, queue: .main) { _ in
            focusMainWindow()
            pluginModel.selectedSidebarItem = .plugin(pluginModel.plugins.first ?? Plugin(name: "", description: ""))
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("ShowAboutPage"), object: nil, queue: .main) { _ in
            focusMainWindow()
            pluginModel.selectedSidebarItem = .about
        }
        observersRegistered = true
    }

    var body: some Scene {
        WindowGroup("main") {
            ContentView()
                .environmentObject(pluginModel)
                .onAppear {
                    SwiftUIPluginListApp.registerObservers(pluginModel: pluginModel)
                    backendManager.startBackendAndConnect { plugins in
                        pluginModel.plugins = plugins
                        pluginModel.selectedPlugin = plugins.first
                    }
                    if menuBarController == nil {
                        menuBarController = MenuBarController()
                    }
                }
        }
        .handlesExternalEvents(matching: Set(["main"]))
    }
}

