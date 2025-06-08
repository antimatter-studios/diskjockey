//
//  AppDelegate.swift
//  DiskJockeyApplication
//
//  Created by Chris Thomas on 02.06.25.
//

import Cocoa
import FileProvider

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem?

    var settingsWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Setup FileProvider domain (existing logic)
        let identifier = NSFileProviderDomainIdentifier(rawValue: "diskjockey")
        let domain = NSFileProviderDomain(identifier: identifier, displayName: "Disk Jockey")
        NSFileProviderManager.add(domain) { error in
            guard let error = error else {
                return
            }
            NSLog(error.localizedDescription)
        }

        // Add menu bar (status bar) icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "Disk Jockey")
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(showSettings), keyEquivalent: ","))
        
        
        statusItem?.menu = menu
    }

    @IBAction @objc func showSettings(_ sender: NSMenuItem) {
        if settingsWindowController == nil {
            let storyboard = NSStoryboard(name: "Main", bundle: nil)
            settingsWindowController = storyboard.instantiateController(withIdentifier: "SettingsWindowController") as? NSWindowController
        }
        settingsWindowController?.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction @objc func showAbout(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "About Disk Jockey"
        alert.informativeText = "Disk Jockey\nA cross-platform file and mount manager.\n\nVersion 1.0\nBy Chris Thomas."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        print("You opened the about dialog")
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
        print("FIXME: You should disconnect all mounts here")
    }
}

