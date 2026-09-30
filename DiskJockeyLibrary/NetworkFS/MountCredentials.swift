//
// MountCredentials.swift — the credentials a mount config holds in memory
// but never encodes, and the keychain items that hold them instead.
//
// The mount's password (or secret key, or refresh token) has always been a
// keychain item keyed by domain ID and passed to `mountJSON(password:)`.
// Some configs carry a second credential as a field: today that is S3's
// STS `sessionToken`, which the driver needs to sign requests and nothing
// refreshes. Its encoder omits it, so neither the per-domain plist nor the
// registry's UserDefaults blob carries it (diskjockey#172); this type puts
// it in the keychain beside the secret key and back into the config after
// a load.
//
// `resolvedConfig(domainID:store:)` is what the File Provider extension
// loads a mount through, so a plist written by an older build — which does
// still carry the token — is migrated by whichever process reads it first.
// The extension does not wait for the host app to have run.
//

import Foundation

/// The keychain operations `MountCredentials` needs; `MountKeychain`
/// provides them. A protocol so the tests can run with no keychain
/// access group entitlement.
public protocol MountSecretStore: Sendable {
    func save(password: String, domainID: String) throws
    func load(domainID: String) throws -> String
    func delete(domainID: String) throws
}

extension MountKeychain: MountSecretStore {}

public struct MountCredentials: Sendable {
    private let secrets: any MountSecretStore

    public init(secrets: any MountSecretStore = MountKeychain()) {
        self.secrets = secrets
    }

    /// The keychain account holding a mount's S3 session token. Distinct
    /// from the domain ID itself, which is the password's account.
    public static func sessionTokenAccount(domainID: String) -> String {
        "\(domainID).s3-session-token"
    }

    /// Store the credentials `config` carries as fields. An empty token
    /// deletes any stored one, so the keychain never outlives the config's
    /// own idea of whether it has one.
    public func saveFieldSecrets(of config: StoredMountConfig, domainID: String) throws {
        guard case .s3(let s3) = config else { return }
        let account = Self.sessionTokenAccount(domainID: domainID)
        if s3.sessionToken.isEmpty {
            try secrets.delete(domainID: account)
        } else {
            try secrets.save(password: s3.sessionToken, domainID: account)
        }
    }

    /// Remove every field credential stored for `domainID`. Safe to call
    /// for a mount that never had one.
    public func deleteFieldSecrets(domainID: String) throws {
        try secrets.delete(domainID: Self.sessionTokenAccount(domainID: domainID))
    }

    /// `config` with its field credentials read back from the keychain. A
    /// missing item is an absent credential, not an error: most S3 mounts
    /// have no session token.
    public func hydrate(_ config: StoredMountConfig, domainID: String) throws -> StoredMountConfig {
        guard case .s3(let s3) = config, s3.sessionToken.isEmpty else { return config }
        do {
            let token = try secrets.load(domainID: Self.sessionTokenAccount(domainID: domainID))
            return .s3(s3.withSessionToken(token))
        } catch MountKeychainError.notFound {
            return config
        }
    }

    /// Load `domainID`'s config from `store` with its field credentials in
    /// place. A plist from an older build that still carries one has it
    /// moved into the keychain and the plist rewritten without it. The
    /// rewrite only follows a successful keychain save, so a failed save
    /// leaves the credential where it was rather than losing it.
    public func resolvedConfig(domainID: String, store: MountConfigStore) throws -> StoredMountConfig {
        let config = try store.load(domainID: domainID)
        if case .s3(let s3) = config, !s3.sessionToken.isEmpty {
            do {
                try saveFieldSecrets(of: config, domainID: domainID)
                try store.save(config, domainID: domainID)
            } catch {
                NSLog("[MountCredentials] could not move %@'s session token out of its plist: %@",
                      domainID, "\(error)")
            }
            return config
        }
        return try hydrate(config, domainID: domainID)
    }
}
