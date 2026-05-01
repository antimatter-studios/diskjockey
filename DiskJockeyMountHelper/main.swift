//
// main.swift — DiskJockeyMountHelper entry point.
//
// Spike: launchd spawns this binary as root via SMAppService.daemon,
// it listens on a Mach service, replies to `ping(reply:)` with its
// process identity. The main app then knows two things: (a) launchd
// accepted our binary (no Launch Constraint Violation — the failure
// mode that bit the Go backend in this project's history), and (b)
// we genuinely have root privileges to call DADiskMount with.
//
// MIT License — see LICENSE
//

import Foundation
import os

private let log = OSLog(
    subsystem: "com.antimatterstudios.diskjockey.mounthelper",
    category: "main")

final class HelperService: NSObject, MountHelperProtocol {
    func ping(reply: @escaping (String) -> Void) {
        let info = "alive: pid=\(getpid()) uid=\(getuid()) euid=\(geteuid())"
        os_log("ping → %{public}@", log: log, type: .info, info)
        reply(info)
    }
}

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection conn: NSXPCConnection
    ) -> Bool {
        // Spike: accept any caller. Real impl will validate the audit
        // token's code-signing requirement so only DiskJockey.app can
        // talk to us. Until then a privileged helper accepting any
        // peer is a security smell — fine for a local-dev spike, NOT
        // for shipping.
        conn.exportedInterface = NSXPCInterface(with: MountHelperProtocol.self)
        conn.exportedObject = HelperService()
        conn.resume()
        return true
    }
}

os_log("MountHelper starting: pid=%d uid=%d", log: log, type: .info, getpid(), getuid())

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: mountHelperMachServiceName)
listener.delegate = delegate
listener.resume()

// Block forever — launchd manages our lifecycle, we just service requests.
RunLoop.main.run()
