//
// MountKeychain.swift — password storage for direct mounts, shared
// between the host app (writes) and the FileProvider extension (reads)
// via a keychain-access-group.
//
// Both targets carry the entitlement:
//
//   keychain-access-groups = [ "$(AppIdentifierPrefix)group.com.antimatterstudios.diskjockey" ]
//
// which lets us put one item in the keychain that either side can look
// up by (service, account). `kSecAttrSynchronizable` is always NO — a
// mount credential is local-device state, not iCloud-synced.
//

import Foundation
import Security

public enum MountKeychainError: Error {
    case osstatus(OSStatus, String)
    case notFound
    case decodeFailed
}

public struct MountKeychain: Sendable {
    public static let service = "com.antimatterstudios.diskjockey.ftp"
    /// The entitlement value (without `$(AppIdentifierPrefix)` since
    /// Security.framework expects the already-prefixed form at runtime).
    /// Both processes resolve this identically because they share the
    /// same team + group.
    public static let accessGroup = "group.com.antimatterstudios.diskjockey"

    public init() {}

    /// Upsert the password. If an item already exists for the
    /// (service, account) pair, its value is replaced.
    public func save(password: String, domainID: String) throws {
        let data = Data(password.utf8)

        // Try update first; if nothing matched, add.
        let updateQuery: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  Self.service,
            kSecAttrAccount as String:  domainID,
            kSecAttrAccessGroup as String: Self.accessGroup,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary,
                                         updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess {
            NSLog("[MountKeychain] updated existing item for %@", domainID)
            return
        }
        if updateStatus != errSecItemNotFound {
            NSLog("[MountKeychain] update FAILED status=%d for %@", updateStatus, domainID)
            throw MountKeychainError.osstatus(updateStatus, "update")
        }

        // No existing item — add.
        var addQuery = updateQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            NSLog("[MountKeychain] add FAILED status=%d for %@ (access-group=%@)",
                  addStatus, domainID, Self.accessGroup)
            throw MountKeychainError.osstatus(addStatus, "add")
        }
        NSLog("[MountKeychain] added new item for %@", domainID)
    }

    public func load(domainID: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  Self.service,
            kSecAttrAccount as String:  domainID,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecReturnData as String:   kCFBooleanTrue as Any,
            kSecMatchLimit as String:   kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw MountKeychainError.notFound
        }
        if status != errSecSuccess {
            throw MountKeychainError.osstatus(status, "load")
        }
        guard let data = result as? Data,
              let s = String(data: data, encoding: .utf8) else {
            throw MountKeychainError.decodeFailed
        }
        return s
    }

    public func delete(domainID: String) throws {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  Self.service,
            kSecAttrAccount as String:  domainID,
            kSecAttrAccessGroup as String: Self.accessGroup,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw MountKeychainError.osstatus(status, "delete")
        }
    }
}
