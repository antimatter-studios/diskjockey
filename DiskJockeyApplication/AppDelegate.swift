//
//  AppDelegate.swift
//  DiskJockeyApplication
//
//  Created by Chris Thomas on 02.06.25.
//

import Cocoa
import DiskJockeyHelperLibrary

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    var tcpListener: TCPListener!
    var messageServer: MessageServer!
    var backendProcess: Process?

    var statusItem: NSStatusItem?

    var settingsWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Start the message server
        messageServer = MessageServer()

        // Start the TCP listener on a random port (0 = let OS choose)
        tcpListener = TCPListener(port: 0) { [weak self] clientFD in
            self?.messageServer.acceptClientSocket(clientFD)
        }

        guard let actualPort = tcpListener.actualPort else {
            NSLog("Failed to get TCP listener port")
            return
        }
        NSLog("TCP listener started on port \(actualPort)")

        // Launch the Go backend, passing the port
        launchBackend(helperPort: actualPort)

        setupStatusBar()
        setupMenuBar()
    }

    private func launchBackend(helperPort: Int) {
        // Find the backend executable (customize the path as needed)
        let fileManager = FileManager.default
        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        
        if let backendURL = Bundle.main.url(forResource: "diskjockey-backend", withExtension: nil) {
            let process = Process()
            process.executableURL = backendURL
            process.arguments = [
                "--config-dir", appSupportDir.appendingPathComponent("DiskJockey").path,
                "--helper-port", String(helperPort)
            ]
            process.terminationHandler = { _ in
                NSLog("Backend process terminated")
            }
            do {
                try process.run()
                backendProcess = process
                NSLog("Launched backend with --helper-port \(helperPort)")
            } catch {
                NSLog("Failed to launch backend: \(error)")
            }
        } else {
            NSLog("Failed to find backend executable")
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
        // Stop the TCP listener and message server
        messageServer?.stop()
        messageServer = nil
        tcpListener?.disconnect()
        tcpListener = nil
        // Terminate backend process if running
        backendProcess?.terminate()
        backendProcess = nil
    }
}
