//
// GDriveMountConfig.swift — personality for the Google Drive driver.
//
// The Go driver (vendor/go-networkfs/gdrive/gdrive.go) authenticates via
// the OAuth2 refresh-token flow and needs three inputs:
//
//   client_id      — public; persisted here
//   client_secret  — semi-secret; persisted here (OAuth2 "installed app"
//                    secrets are not treated as high-value credentials
//                    by Google, which is why shipping them in-app is
//                    standard practice — but we keep them out of the
//                    password slot so the keychain item is strictly
//                    the refresh token)
//   refresh_token  — sensitive; passed in as `password` from the
//                    shared keychain at mount time
//
// An `access_token` held in memory is forwarded too, and the driver
// validates it and refreshes if it has expired. It is never persisted: see
// `CodingKeys` (diskjockey#160).
//

import Foundation

public struct GDriveMountConfig: NetworkFSPersonality {
    public static let scheme: DirectMountScheme = .gdrive

    public let clientID: String
    public let clientSecret: String
    /// Optional short-lived token. Leave empty and the Go driver will
    /// refresh on first use.
    public let cachedAccessToken: String
    /// Optional cached account label (e.g. "user@example.com") for
    /// the detail view. Filled at sign-in time from
    /// `userinfo.email`. Empty when we never grabbed it.
    public let accountLabel: String

    public init(clientID: String, clientSecret: String, cachedAccessToken: String = "", accountLabel: String = "") {
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
            "client_secret": clientSecret,
            "refresh_token": password,
        ]
        if !cachedAccessToken.isEmpty {
            dict["access_token"] = cachedAccessToken
        }
        return encodeMountDict(dict)
    }
}
