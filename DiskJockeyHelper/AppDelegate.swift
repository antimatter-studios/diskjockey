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

    var messageServer: MessageServer!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSLog("DiskJockeyHelper started, now initializing TCP Listener")

        let server = MessageServer()
        self.messageServer = server

        let helperSocket = TCPListener(port: 0) { [weak self] clientFD in
            guard let self = self else { return }
            self.messageServer?.acceptClientSocket(clientFD)
        }
        
        let port = helperSocket.actualPort ?? 0
        // Post port to main app via NSDistributedNotificationCenter
        let userInfo: [AnyHashable: Any] = ["port": port]
        DistributedNotificationCenter.default().post(name: Notification.Name("DiskJockeyHelperPort"),
                                                    object: nil,
                                                    userInfo: userInfo)
        // print("LISTEN_PORT=\(port)")
        // fflush(stdout)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        messageServer.stop()
        messageServer = nil
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }


}

