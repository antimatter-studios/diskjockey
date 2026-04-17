import Cocoa
import SwiftUI

class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!

    override init() {
        super.init()
        setupMenuBar()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "DiskJockey")
        }

        let menu = NSMenu()

        let showItem = NSMenuItem(title: "Show DiskJockey", action: #selector(showMainWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func showMainWindow() {
        NotificationCenter.default.post(name: NSNotification.Name("ShowMainWindow"), object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension MenuBarController: NSMenuDelegate {}
