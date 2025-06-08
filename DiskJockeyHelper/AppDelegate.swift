//
//  AppDelegate.swift
//  DiskJockeyHelper
//
//  Created by Chris Thomas on 07.06.25.
//

import Cocoa
import DiskJockeyHelperLibrary

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    var ipcServer: DiskJockeyIPCServer?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Minimal IPC server implementation
        // Handles graceful shutdown on shutdown command (type 99) a UNIX domain socket
        let socketPath = "/tmp/diskjockey.helper.sock"
        ipcServer = DiskJockeyIPCServer(socketPath: socketPath)
        do {
            try ipcServer?.start()
            NSLog("DiskJockeyHelper: IPC server started on \(socketPath)")
        } catch {
            NSLog("DiskJockeyHelper: Failed to start IPC server: \(error)")
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Clean up the IPC server
        ipcServer?.stop()
        ipcServer = nil
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }


}

