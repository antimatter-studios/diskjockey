import Foundation

private let kTeamID = "43UMKXZ8P4"

final class AgentDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        // Only accept connections from our own app, signed by our team.
        // `setCodeSigningRequirement` (macOS 13+) is the public, recommended
        // replacement for the manual audit-token + SecCode validation —
        // `NSXPCConnection.auditToken` is not public API. The connection is
        // invalidated automatically if the peer doesn't satisfy the rule.
        conn.setCodeSigningRequirement(
            "identifier \"com.antimatterstudios.diskjockey\" and certificate leaf[subject.OU] = \"\(kTeamID)\"")
        conn.exportedInterface = NSXPCInterface(with: DJAgentProtocol.self)
        conn.exportedObject = AgentImpl()
        conn.resume()
        return true
    }
}

let delegate = AgentDelegate()
let listener = NSXPCListener(machServiceName: "com.antimatterstudios.diskjockey.agent")
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
