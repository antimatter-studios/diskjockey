//
// MountHelperProtocol.swift — shared XPC vocabulary between the
// DiskJockey host app (sandboxed user context) and the launchd-spawned
// privileged mount helper (root context).
//
// This file is added to BOTH targets' Compile Sources phases so the
// types match by Swift identity at runtime — no framework-link gymnastics
// for the helper just to consume one protocol.
//
// Spike scope: a single `ping(reply:)` call. The helper replies with
// its pid + uid + euid so the main app's log can confirm the helper
// is actually running in the privileged context launchd promised.
// Real mount RPCs (mount(bsd:reply:)) get added once the spike
// confirms launchd accepts the binary.
//
// MIT License — see LICENSE
//

import Foundation

@objc public protocol MountHelperProtocol {
    /// Liveness + privilege check. Reply carries a free-form string the
    /// app logs verbatim. No structured fields yet — this is a spike.
    func ping(reply: @escaping (String) -> Void)
}

/// Mach service name. Same string in three places: the helper's
/// `NSXPCListener(machServiceName:)`, the launchd plist's
/// `MachServices` dict, and the host app's
/// `NSXPCConnection(machServiceName:)`. Centralising it here means a
/// rename can't desync.
public let mountHelperMachServiceName = "com.antimatterstudios.diskjockey.mounthelper"
