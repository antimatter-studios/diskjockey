import Foundation

/// Also spelled in `DiskJockeyApplication/Services/DJAgentClient.swift`
/// as `teamID`. Two copies, because this agent is not an Xcode target
/// and shares no compilation unit with the app — if one is ever changed
/// without the other, the app and its helper stop being able to talk
/// and neither says why. Change both.
private let kTeamID = "43UMKXZ8P4"

final class AgentDelegate: NSObject, NSXPCListenerDelegate {
    /// One ledger for every connection: an image attached over one
    /// connection is detached over another after the app relaunches.
    private let ledger = AttachLedgerFile(url: AttachLedgerFile.defaultURL)

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        // Only accept connections from our own app, signed by our team.
        // `setCodeSigningRequirement` (macOS 13+) is the public, recommended
        // replacement for the manual audit-token + SecCode validation —
        // `NSXPCConnection.auditToken` is not public API. The connection is
        // invalidated automatically if the peer doesn't satisfy the rule.
        //
        // `anchor apple generic` was missing. Without it the rule asks
        // for an identifier and a team OU on the leaf certificate, and
        // says nothing about who issued that certificate — a
        // self-signed leaf carrying the same two fields satisfies it.
        // The anchor is what requires an Apple-issued chain.
        conn.setCodeSigningRequirement(
            "anchor apple generic and identifier \"com.antimatterstudios.diskjockey\" "
            + "and certificate leaf[subject.OU] = \"\(kTeamID)\"")
        conn.exportedInterface = NSXPCInterface(with: DJAgentProtocol.self)
        conn.exportedObject = AgentImpl(ledger: ledger)
        conn.resume()
        return true
    }
}

let delegate = AgentDelegate()
let listener = NSXPCListener(machServiceName: "com.antimatterstudios.diskjockey.agent")
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
