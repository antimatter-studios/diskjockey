import SwiftUI
import Foundation

@main
struct DiskJockeyApp: App {
    @State private var menuBarController: MenuBarController? = nil
    @StateObject var pluginModel = PluginModel()
    @StateObject var backendManager = BackendManager()
    @StateObject var sidebarModel = SidebarModel()

    // Remove observer registration from init to avoid 'mutating self' capture
    // We'll register observers in .onAppear using a static helper
    static var observersRegistered = false
    static func registerObservers(pluginModel: PluginModel, sidebarModel: SidebarModel) {
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
            sidebarModel.selectedItem = .plugins
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("ShowAboutPage"), object: nil, queue: .main) { _ in
            focusMainWindow()
            sidebarModel.selectedItem = .about
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("ShowQuitPage"), object: nil, queue: .main) { _ in
            focusMainWindow()
            sidebarModel.selectedItem = .quit
        }
        observersRegistered = true
    }

    var body: some Scene {
        WindowGroup("main") {
            ContentView()
                .environmentObject(pluginModel)
                .environmentObject(sidebarModel)
                .onAppear {
                    DiskJockeyApp.registerObservers(pluginModel: pluginModel, sidebarModel: sidebarModel)
                    backendManager.startBackendAndConnect { plugins in
                        pluginModel.plugins = plugins
                    }
                    if menuBarController == nil {
                        menuBarController = MenuBarController()
                    }
                }
        }
        .handlesExternalEvents(matching: Set(["main"]))
    }
}

