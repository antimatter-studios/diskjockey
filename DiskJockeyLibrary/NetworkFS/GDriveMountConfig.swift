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

    public init(clientID: String, clientSecret: String, cachedAccessToken: String = "") {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.cachedAccessToken = cachedAccessToken
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
