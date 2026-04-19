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
    private let container = AppContainer()
    private var mainWindowController: NSWindowController?
    private var aboutWindowController: NSWindowController?
    private var cancellables = Set<AnyCancellable>()

    private var contentView: some View {
        ContentView(container: container)
            .environmentObject(container.appLogModel)
    }

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Starting Disk Jockey...")
        setupMainMenu()
        container.startBackend()
        showMainWindow()
        setupErrorObservation()
        registerFileProviderDomain()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Backend keeps running as LaunchAgent — nothing to clean up
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = appMenu.addItem(
            withTitle: "About DiskJockey",
            action: #selector(showAboutWindow(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit DiskJockey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let attachEXT4 = fileMenu.addItem(
            withTitle: "Attach ext4 image…",
            action: #selector(attachEXT4Image),
            keyEquivalent: "e"
        )
        attachEXT4.keyEquivalentModifierMask = [.command, .shift]
        attachEXT4.target = self
        let attachNTFS = fileMenu.addItem(
            withTitle: "Attach NTFS image…",
            action: #selector(attachNTFSImage),
            keyEquivalent: "n"
        )
        attachNTFS.keyEquivalentModifierMask = [.command, .shift]
        attachNTFS.target = self
        let detachVolume = fileMenu.addItem(
            withTitle: "Detach volume…",
            action: #selector(detachEXT4Volume),
            keyEquivalent: "u"
        )
        detachVolume.keyEquivalentModifierMask = [.command, .shift]
        detachVolume.target = self
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu (required for copy/paste in SwiftUI text fields)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Window

    @objc private func attachEXT4Image() {
        FSKitAttachController.promptAndAttach(fsType: "ext4", logRepository: container.logRepository)
    }

    @objc private func attachNTFSImage() {
        FSKitAttachController.promptAndAttach(fsType: "ntfs", logRepository: container.logRepository)
    }

    @objc private func detachEXT4Volume() {
        FSKitAttachController.promptAndDetach(logRepository: container.logRepository)
    }

    @objc private func showMainWindow() {
        if mainWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )

            window.center()
            window.setFrameAutosaveName("Main Window")
            window.title = "DiskJockey"
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: contentView)

            let windowController = NSWindowController(window: window)
            self.mainWindowController = windowController
        }

        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAboutWindow(_ sender: Any?) {
        if aboutWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )

            window.title = "About DiskJockey"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AboutView())
            window.center()

            let windowController = NSWindowController(window: window)
            self.aboutWindowController = windowController
        }

        aboutWindowController?.showWindow(nil)
        aboutWindowController?.window?.makeKeyAndOrderFront(nil)
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

                    do {
                        try await container.backendAPI.mount(id: mountID)
                        print("Activated mount \(mountID): \(mount.name)")
                    } catch {
                        print("Failed to activate mount \(mountID): \(error)")
                    }

                    let domainID = NSFileProviderDomainIdentifier(rawValue: String(mountID))
                    let domain = NSFileProviderDomain(identifier: domainID, displayName: mount.name)

                    do {
                        try await NSFileProviderManager.add(domain)
                        print("Registered FP domain: \(mount.name) (id: \(mountID))")

                        if let manager = NSFileProviderManager(for: domain) {
                            manager.signalEnumerator(for: .rootContainer) { _ in }
                            manager.signalEnumerator(for: .workingSet) { _ in }
                        }
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
