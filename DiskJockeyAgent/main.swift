import Foundation

private let kTeamID = "43UMKXZ8P4"

final class AgentDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        guard let token = conn.auditToken as? audit_token_t else {
            return false
        }
        var code: SecCode?
        var attr = [kSecGuestAttributeAudit: NSData(bytes: &token, length: MemoryLayout<audit_token_t>.size)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attr, [], &code) == errSecSuccess,
              let code else { return false }
        var requirement: SecRequirement?
        let reqStr = "identifier com.antimatterstudios.diskjockey and certificate leaf[subject.OU] = \"\(kTeamID)\"" as CFString
        guard SecRequirementCreateWithString(reqStr, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
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
