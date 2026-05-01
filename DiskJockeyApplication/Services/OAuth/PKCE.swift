//
// PKCE.swift — RFC 7636 helpers for OAuth 2.0 Authorization Code with
// Proof Key for Code Exchange. Public clients (desktop / mobile)
// can't ship a `client_secret`; PKCE binds the auth-code exchange to
// a one-time secret (the `code_verifier`) that only the client
// process holds in memory, so an intercepted code is useless without
// it.
//
// We use the `S256` challenge method (SHA-256 of verifier, then
// base64url) — the only method modern providers accept for new apps.
//

import CryptoKit
import Foundation

public struct PKCE: Sendable {
    /// 43–128 char URL-safe random string. Stays in process memory
    /// until we POST to the token endpoint, then is dropped.
    public let codeVerifier: String
    /// Sent to the authorize endpoint; derived from `codeVerifier`
    /// via SHA-256 + base64url. The provider stores this; only the
    /// holder of the original verifier can complete the exchange.
    public let codeChallenge: String

    public init() {
        let verifier = PKCE.makeVerifier()
        self.codeVerifier = verifier
        self.codeChallenge = PKCE.challenge(for: verifier)
    }

    /// 64 random bytes → base64url → ~86 char verifier (well under
    /// the 128 cap; well above the 43 floor). Random source is
    /// `SystemRandomNumberGenerator` via `Data` extension below.
    private static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: 0...UInt8.max)
        }
        return base64URL(Data(bytes))
    }

    private static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    /// RFC 4648 §5 base64url-without-padding. Standard for
    /// OAuth/PKCE/JWT tokens — `+/=` swapped to `-_` and stripped.
    private static func base64URL(_ data: Data) -> String {
        let b64 = data.base64EncodedString()
        return b64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
