//
//  AppDelegate.swift
//  DiskJockeyApplication
//
//  Created by Chris Thomas on 02.06.25.
//

import Cocoa
import FileProvider
import DiskJockeyHelperLibrary

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    var helperProcessManager: HelperProcessManager!
    var helperAPI: HelperAPI!

    var statusItem: NSStatusItem?

    var settingsWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        helperProcessManager = HelperProcessManager()
        launchHelperPhase()

        setupFileProvider()
        setupStatusBar()
        setupMenuBar()
    }

    private func launchHelperPhase() {
        helperProcessManager.launchAndMonitorHelper { [weak self] helperPort in
            guard let self = self else { return }
            if let helperPort = helperPort {
                self.launchBackendPhase(helperPort: helperPort)
            } else {
                NSLog("Failed to get helper port from DiskJockeyHelper")
            }
        }
    }

    private func launchBackendPhase(helperPort: Int) {
        helperProcessManager.launchAndMonitorBackend(helperPort: helperPort) { [weak self] success in
            guard let self = self else { return }
            if success != nil {
                self.connectToHelperPhase(helperPort: helperPort)
            } else {
                NSLog("Failed to launch backend")
            }
        }
    }

    private func connectToHelperPhase(helperPort: Int) {
        let connection = TCPConnection(host: "127.0.0.1", port: helperPort)
        self.helperAPI = HelperAPI(socket: connection)
        self.helperAPI.connect(role: .app) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                NSLog("App CONNECT handshake with helper succeeded")
                // TODO: Start listening for async events/messages from helper
            case .failure(let error):
                fatalError("App CONNECT handshake with helper failed: \(error)")
            }
        }
    }
    
    private func setupFileProvider() {
        let identifier = NSFileProviderDomainIdentifier(rawValue: "diskjockey")
        let domain = NSFileProviderDomain(identifier: identifier, displayName: "Disk Jockey")
        NSFileProviderManager.add(domain) { error in
            guard let error = error else {
                return
            }
            NSLog(error.localizedDescription)
        }
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "Disk Jockey")
        }
    }

    private func setupMenuBar() {
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

