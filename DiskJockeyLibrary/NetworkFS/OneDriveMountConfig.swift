//
// OneDriveMountConfig.swift — personality for the Microsoft OneDrive
// driver.
//
// Same OAuth2 refresh-token shape as Google Drive:
//
//   client_id      — Azure app registration client ID (required)
//   client_secret  — optional; public clients use PKCE and omit this
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

    public init(clientID: String, clientSecret: String = "", cachedAccessToken: String = "") {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.cachedAccessToken = cachedAccessToken
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
