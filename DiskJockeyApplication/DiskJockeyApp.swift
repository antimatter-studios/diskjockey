import SwiftUI
import Foundation

@main
struct DiskJockeyApp: App {
    @StateObject var pluginModel = PluginModel()
    @StateObject var backendManager = BackendManager()
    @State private var menuBarController: MenuBarController? = nil

    // Remove observer registration from init to avoid 'mutating self' capture
    // We'll register observers in .onAppear using a static helper
    static var observersRegistered = false
    static func registerObservers(pluginModel: PluginModel) {
        guard !observersRegistered else { return }
        func focusMainWindow() {
            // Only open the custom URL scheme if no main window is visible
            let isMainWindowOpen = NSApplication.shared.windows.contains(where: { $0.isVisible && $0.level == .normal })
            if !isMainWindowOpen, let url = URL(string: "myapp://main") {
                NSWorkspace.shared.open(url)
            } else if isMainWindowOpen {
                // If already open, bring to front
                NSApplication.shared.windows.filter { $0.isVisible && $0.level == .normal }.forEach { $0.makeKeyAndOrderFront(nil) }
                NSApp.activate(ignoringOtherApps: true)
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
                    DiskJockeyApp.registerObservers(pluginModel: pluginModel)
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

