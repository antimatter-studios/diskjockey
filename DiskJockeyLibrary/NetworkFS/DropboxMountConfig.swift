//
// DropboxMountConfig.swift — personality for the Dropbox driver.
//
// Dropbox is a public OAuth2 client (PKCE flow, no client_secret).
// What goes on the wire to the Go driver:
//
//   {
//     "app_key":       "<the developer's Dropbox App Key>",
//     "refresh_token": "<per-user, from MountKeychain>"
//   }
//
// The Go driver mints a fresh ~4 h `access_token` from the
// refresh_token at mount time and on demand whenever the access
// token has aged out. We never persist access tokens — they're
// derived from the refresh token and the app key.
//
// On-disk plist carries the `app_key` (it's a public client_id per
// RFC 8252 / PKCE) and a cached account display name if we have one;
// the refresh token lives only in the macOS keychain via
// `MountKeychain`.
//
// Backward-compat note: an older shape used a long-lived
// `access_token` as the sole credential. Existing mounts persisted
// in that shape decode here as `appKey == ""` — the Go driver still
// supports that legacy config key for one release while users
// re-authenticate.
//
// Per-mount policy flags (`fetchThumbnails`, `backgroundFetch`)
// don't live on the protocol-specific config — they're stored
// alongside via `MountPolicyStore` so every connector carries the
// same toggles.
//

import Foundation

public struct DropboxMountConfig: NetworkFSPersonality {
    public static let scheme: DirectMountScheme = .dropbox

    /// Dropbox App Key, persisted into the mount plist. Public per
    /// PKCE design; we keep it on the mount rather than reading
    /// `OAuthClientConfig.dropbox` at mount time so re-keying the
    /// app down the road doesn't break already-paired mounts.
    /// Empty for legacy mounts created before the OAuth flow
    /// existed — those carry a long-lived access token in the
    /// keychain and round-trip via the Go driver's `access_token`
    /// config key for one release.
    public let appKey: String

    /// Optional cached account label (e.g. "user@example.com") for
    /// the detail view. Filled at sign-in time from
    /// `account_info.read`. Empty when we never grabbed it.
    public let accountLabel: String

    public init(appKey: String = "", accountLabel: String = "") {
        self.appKey = appKey
        self.accountLabel = accountLabel
    }

    private enum CodingKeys: String, CodingKey {
        case appKey, accountLabel
    }

    /// Custom decode so old persisted plists (`{}`, no fields) still
    /// load — they'll come back as `appKey == ""` and route through
    /// the legacy mountJSON branch below.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.appKey = (try? c.decode(String.self, forKey: .appKey)) ?? ""
        self.accountLabel = (try? c.decode(String.self, forKey: .accountLabel)) ?? ""
    }

    public func mountJSON(password: String) -> String {
        if appKey.isEmpty {
            // Legacy long-lived access-token mount (no app_key on
            // disk). Round-trip the token through the Go driver's
            // legacy `access_token` config key. Users should
            // re-create the mount via the Sign in flow when
            // convenient — Dropbox is deprecating long-lived tokens.
            return encodeMountDict([
                "access_token": password,
            ])
        }
        // Modern PKCE mount. The Go driver wraps {app_key,
        // refresh_token} in an oauth2-managed http.Client and
        // mints fresh access tokens on demand.
        return encodeMountDict([
            "app_key":       appKey,
            "refresh_token": password,
        ])
    }
}
