import SwiftUI
import FileProvider
import Foundation
import DiskJockeyLibrary
import AppKit
import Combine

@main
class DiskJockeyApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties
    
    /// The main dependency container for the application
    private let container = AppContainer()
    
    /// The main window controller
    private var mainWindowController: NSWindowController?
    
    /// Status bar item for the app
    private var statusItem: NSStatusItem?
    
    /// Combine cancellables
    private var cancellables = Set<AnyCancellable>()
    
    /// The SwiftUI content view
    private var contentView: some View {
        ContentView(container: container)
    }
    
    // MARK: - Application Lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Starting Disk Jockey...")

        // Start the backend
        container.startBackend()
        
        // Setup status bar item
        setupStatusBarItem()
        
        // Show the main window
        showMainWindow()
        
        // Observe for errors
        setupErrorObservation()
        
        // Register file provider domain
        registerFileProviderDomain()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Clean up resources
        // The backend process will be terminated by the system
    }
    
    // MARK: - UI Setup
    
    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "DiskJockey")
        }
        
        let statusMenu = NSMenu()
        
        let showWindowItem = NSMenuItem(
            title: "Show DiskJockey",
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        showWindowItem.target = self
        statusMenu.addItem(showWindowItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(
            title: "Quit DiskJockey",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusMenu.addItem(quitItem)
        
        statusItem?.menu = statusMenu
    }
    
    @objc private func showMainWindow() {
        // Create the main window if it doesn't exist
        if mainWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            
            window.center()
            window.setFrameAutosaveName("Main Window")
            window.title = "DiskJockey"
            window.contentView = NSHostingView(rootView: contentView)
            
            let windowController = NSWindowController(window: window)
            self.mainWindowController = windowController
        }
        
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - Error Handling
    
    @MainActor
    private func setupErrorObservation() {
        container.$error
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                if let error = error {
                    self?.showError(error)
                }
            }
            .store(in: &cancellables)
    }
    
    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "An error occurred"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        
        // Show the alert as a sheet if we have a window, otherwise as a modal
        if let window = mainWindowController?.window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }
    
    // MARK: - File Provider
    
    private func registerFileProviderDomain() {
        // TODO: Implement file provider domain registration
    }
}


