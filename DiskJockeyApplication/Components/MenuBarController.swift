import Cocoa
import SwiftUI

class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private let sidebarModel: SidebarModel
    
    init(sidebarModel: SidebarModel) {
        self.sidebarModel = sidebarModel
        super.init()
        setupMenuBar()
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "Disk Jockey")
        }
        
        let menu = NSMenu()
        
        let aboutItem = NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        
        let settingsItem = NSMenuItem(title: "Settings", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(showQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    @objc private func showAbout() {
        sidebarModel.selectedItem = .about
        NotificationCenter.default.post(name: NSNotification.Name("ShowAboutPage"), object: nil)
        NotificationCenter.default.post(name: NSNotification.Name("ShowMainWindow"), object: nil)
    }
    
    @objc private func showSettings() {
        sidebarModel.selectedItem = .plugins
        NotificationCenter.default.post(name: NSNotification.Name("ShowSettingsPage"), object: nil)
        NotificationCenter.default.post(name: NSNotification.Name("ShowMainWindow"), object: nil)
    }
    
    @objc private func showQuit() {
        sidebarModel.selectedItem = .quit
        NotificationCenter.default.post(name: NSNotification.Name("ShowQuitPage"), object: nil)
        NotificationCenter.default.post(name: NSNotification.Name("ShowMainWindow"), object: nil)
    }
}

extension MenuBarController: NSMenuDelegate {}
