//
// DropboxMountConfig.swift — personality for the Dropbox driver.
//
// Dropbox uses an OAuth2 access token as the sole credential; there's
// no host, port, or username to configure on the client side. Every
// value that identifies the account lives inside the token, which we
// keep in the keychain (not in this struct).
//
// As a result this struct is intentionally empty at the wire level —
// the plist on disk looks like `{}` — and `mountJSON` just forwards the
// `password` argument (the access token, from keychain) into the Go
// driver's `access_token` config key.
//
// If we ever want to cache an account email / display name for UI, add
// a non-sensitive field here; never add the token itself.
//

import Foundation

public struct DropboxMountConfig: NetworkFSPersonality {
    public static let scheme: DirectMountScheme = .dropbox

    public init() {}

    public func mountJSON(password: String) -> String {
        // `password` carries the OAuth2 access token from MountKeychain.
        encodeMountDict([
            "access_token": password,
        ])
    }
}
