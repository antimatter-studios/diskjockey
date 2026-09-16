//
// OneDriveMountConfig.swift — personality for the Microsoft OneDrive
// driver.
//
// Same OAuth2 refresh-token shape as Google Drive, but the desktop
// "public client" profile (PKCE, no client_secret) per Microsoft's
// recommendation for native apps:
//
//   client_id      — Azure app registration client ID (required)
//   client_secret  — empty for our PKCE flow; the field stays for
//                    compat with confidential-client deployments
//   refresh_token  — sensitive; stored in the shared keychain and
//                    passed as `password` at mount time
//
// The Go driver (vendor/go-networkfs/onedrive/onedrive.go) needs the
// `offline_access` scope on the token or refresh will fail.
//

import Foundation

public struct OneDriveMountConfig: NetworkFSPersonality {
    public static let scheme: DirectMountScheme = .onedrive

    public let clientID: String
    /// Empty for public (PKCE) clients; required for confidential ones.
    public let clientSecret: String
    public let cachedAccessToken: String
    /// Optional cached account label (e.g. "user@outlook.com") for
    /// the detail view. Filled at sign-in time from Microsoft Graph
    /// `/me` (`userPrincipalName` or `mail`). Empty when we never
    /// grabbed it.
    public let accountLabel: String

    public init(
        clientID: String,
        clientSecret: String = "",
        cachedAccessToken: String = "",
        accountLabel: String = ""
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.cachedAccessToken = cachedAccessToken
        self.accountLabel = accountLabel
    }

    /// `cachedAccessToken` is deliberately NOT a coding key (diskjockey#160).
    /// It is a live bearer token, and this struct is persisted as a plist in
    /// the app-group container and JSON-encoded into UserDefaults; the
    /// refresh token, the long-lived half, lives in `MountKeychain`. The
    /// driver refreshes on first use when no access token is passed.
    private enum CodingKeys: String, CodingKey {
        case clientID, clientSecret, accountLabel
    }

    /// Custom decode so plists written before `accountLabel` existed
    /// still load — the missing field defaults to empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.clientID = (try? c.decode(String.self, forKey: .clientID)) ?? ""
        self.clientSecret = (try? c.decode(String.self, forKey: .clientSecret)) ?? ""
        // A token written by an older build is not read back, so it is not
        // forwarded and the next save removes it from disk.
        self.cachedAccessToken = ""
        self.accountLabel = (try? c.decode(String.self, forKey: .accountLabel)) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientID, forKey: .clientID)
        try c.encode(clientSecret, forKey: .clientSecret)
        try c.encode(accountLabel, forKey: .accountLabel)
    }

    public func mountJSON(password: String) -> String {
        // `password` carries the OAuth2 refresh token from MountKeychain.
        var dict: [String: String] = [
            "client_id":     clientID,
            "refresh_token": password,
        ]
        if !clientSecret.isEmpty {
            dict["client_secret"] = clientSecret
        }
        if !cachedAccessToken.isEmpty {
            dict["access_token"] = cachedAccessToken
        }
        return encodeMountDict(dict)
    }
}
