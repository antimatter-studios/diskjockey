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
// If an `access_token` is already cached it's forwarded too; the driver
// validates it and falls back to a refresh if it's expired.
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

    private enum CodingKeys: String, CodingKey {
        case clientID, clientSecret, cachedAccessToken, accountLabel
    }

    /// Custom decode so plists written before `accountLabel` existed
    /// still load — the missing field defaults to empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.clientID = (try? c.decode(String.self, forKey: .clientID)) ?? ""
        self.clientSecret = (try? c.decode(String.self, forKey: .clientSecret)) ?? ""
        self.cachedAccessToken = (try? c.decode(String.self, forKey: .cachedAccessToken)) ?? ""
        self.accountLabel = (try? c.decode(String.self, forKey: .accountLabel)) ?? ""
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
