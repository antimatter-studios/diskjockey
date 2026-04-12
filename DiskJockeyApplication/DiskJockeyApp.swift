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
            .environmentObject(container.appLogModel)
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
        print("App error: \(error.localizedDescription)")
        // Show alert non-modally as a sheet if window is available
        if let window = mainWindowController?.window {
            let alert = NSAlert()
            alert.messageText = "An error occurred"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window) { _ in }
        }
    }
    
    // MARK: - File Provider
    
    private func registerFileProviderDomain() {
        // Wait for backend connection, then register FP domains for all mounts
        container.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard case .connected = state else { return }
                self?.activateMountsAndRegisterDomains()
            }
            .store(in: &cancellables)
    }

    private func activateMountsAndRegisterDomains() {
        Task {
            do {
                // Remove all existing domains first to clear stale cached data
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    NSFileProviderManager.removeAllDomains { error in
                        if let error = error {
                            print("Failed to remove domains: \(error)")
                        } else {
                            print("Cleared all File Provider domains")
                        }
                        continuation.resume()
                    }
                }

                let mounts = try await container.backendAPI.listMounts()
                for mount in mounts {
                    guard let mountIDStr = mount.metadata["mount_id"],
                          let mountID = UInt32(mountIDStr) else { continue }

                    // Activate the mount on the backend
                    do {
                        try await container.backendAPI.mount(id: mountID)
                        print("Activated mount \(mountID): \(mount.name)")
                    } catch {
                        print("Failed to activate mount \(mountID): \(error)")
                    }

                    // Register File Provider domain
                    let domainID = NSFileProviderDomainIdentifier(rawValue: String(mountID))
                    let domain = NSFileProviderDomain(identifier: domainID, displayName: mount.name)

                    do {
                        try await NSFileProviderManager.add(domain)
                        print("Registered FP domain: \(mount.name) (id: \(mountID))")
                    } catch {
                        print("Failed to register FP domain: \(error)")
                    }
                }
            } catch {
                print("Failed to list mounts: \(error)")
            }
        }
    }
}


