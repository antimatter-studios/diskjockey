//
// OAuthClientConfig.swift — single accessor for the per-provider
// OAuth client credentials baked into the app bundle.
//
// The values come from `Resources/OAuthClients.json` (gitignored;
// `OAuthClients.example.json` ships in the repo as a template). The
// JSON file is auto-included as a bundle resource because the
// `DiskJockeyApplication` folder is a synchronized root group.
//
// Why a JSON resource instead of hardcoded constants:
//   • One file to glance at to see every provider's keys.
//   • Easy to template + gitignore so a clone doesn't ship anyone
//     else's app registrations.
//   • Same security profile as constants — both end up plaintext in
//     the bundle, and per RFC 8252 (OAuth 2.0 for Native Apps) the
//     `client_id` is *expected* to be public for desktop apps using
//     PKCE. The actually-sensitive value is the per-user
//     `refresh_token`, which lives in `MountKeychain`, not here.
//
// If the JSON is missing or a provider's section is empty, the
// accessor returns `nil` and the AddMount form surfaces a "Dropbox
// sign-in not configured for this build" error rather than crashing.
//

import Foundation

public struct DropboxClientConfig: Equatable, Sendable {
    /// Dropbox App Key — the OAuth `client_id` for our PKCE flow.
    /// Public per Dropbox's documentation for distributed desktop
    /// apps; we still gitignore the JSON file so a fork can't reuse
    /// our app registration.
    public let appKey: String
    /// Whether the Dropbox app was registered with **App folder**
    /// scope (`/Apps/<AppName>/` sandbox) or **Full Dropbox** scope.
    /// Affects which OAuth scope strings we request — App folder
    /// uses the same scope names but Dropbox's server gates access
    /// based on the registration's access type.
    public let scopeKind: ScopeKind

    public enum ScopeKind: String, Sendable {
        case appFolder = "app_folder"
        case fullDropbox = "full_dropbox"
    }
}

public struct GDriveClientConfig: Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String
    /// Whether the OAuth registration was set up for full Drive
    /// access or just the sandboxed `drive.file` scope. Drives the
    /// scope strings the coordinator requests; Google's verification
    /// burden differs sharply between the two (see
    /// docs/google-drive-registration.md §7).
    public let scopeKind: ScopeKind

    public enum ScopeKind: String, Sendable {
        /// `https://www.googleapis.com/auth/drive` — full read/write
        /// to all of the user's Drive. Restricted scope; needs CASA
        /// + verification before non-test users can sign in.
        case fullDrive = "drive"
        /// `https://www.googleapis.com/auth/drive.file` — only files
        /// the app creates or the user explicitly opens with it. No
        /// verification needed but breaks "mount my whole Drive."
        case driveFile = "drive_file"
    }
}

public struct OneDriveClientConfig: Equatable, Sendable {
    public let clientID: String
}

public enum OAuthClientConfig {
    /// Lazy-loaded once per process. Reading the JSON is cheap but
    /// not free; we'd rather not parse it on every OAuth attempt.
    private static let raw: [String: Any] = loadRawJSON()

    /// Dropbox client config, or `nil` if the bundled JSON is
    /// missing the Dropbox section or the App Key wasn't filled in
    /// (still equal to the example placeholder).
    public static var dropbox: DropboxClientConfig? {
        guard
            let dict = raw["dropbox"] as? [String: Any],
            let appKey = nonEmpty(dict["app_key"] as? String),
            !appKey.hasPrefix("REPLACE_WITH_")
        else { return nil }
        let scopeRaw = (dict["scope_kind"] as? String) ?? "full_dropbox"
        let scope = DropboxClientConfig.ScopeKind(rawValue: scopeRaw) ?? .fullDropbox
        return DropboxClientConfig(appKey: appKey, scopeKind: scope)
    }

    public static var gdrive: GDriveClientConfig? {
        guard
            let dict = raw["gdrive"] as? [String: Any],
            let id = nonEmpty(dict["client_id"] as? String),
            let secret = nonEmpty(dict["client_secret"] as? String),
            !id.hasPrefix("REPLACE_WITH_")
        else { return nil }
        let scopeRaw = (dict["scope_kind"] as? String) ?? "drive"
        let scope = GDriveClientConfig.ScopeKind(rawValue: scopeRaw) ?? .fullDrive
        return GDriveClientConfig(clientID: id, clientSecret: secret, scopeKind: scope)
    }

    public static var onedrive: OneDriveClientConfig? {
        guard
            let dict = raw["onedrive"] as? [String: Any],
            let id = nonEmpty(dict["client_id"] as? String),
            !id.hasPrefix("REPLACE_WITH_")
        else { return nil }
        return OneDriveClientConfig(clientID: id)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty else { return nil }
        return s
    }

    private static func loadRawJSON() -> [String: Any] {
        guard let url = Bundle.main.url(forResource: "OAuthClients",
                                        withExtension: "json")
        else {
            AppLog.shared.warn("OAuthClientConfig: Resources/OAuthClients.json not bundled — copy OAuthClients.example.json and fill in your keys")
            return [:]
        }
        do {
            let data = try Data(contentsOf: url)
            let obj = try JSONSerialization.jsonObject(with: data)
            guard let dict = obj as? [String: Any] else {
                AppLog.shared.warn("OAuthClientConfig: OAuthClients.json is not a top-level object")
                return [:]
            }
            return dict
        } catch {
            AppLog.shared.error("OAuthClientConfig: failed to read OAuthClients.json — \(error)")
            return [:]
        }
    }
}
