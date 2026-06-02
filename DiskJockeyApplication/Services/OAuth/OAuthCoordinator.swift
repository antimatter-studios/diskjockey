//
// OAuthCoordinator.swift — drives the Authorization Code + PKCE flow
// for any provider, returns the resulting tokens.
//
// Lifecycle (one call):
//   1. Build a `PKCE` pair + a random `state` (CSRF guard).
//   2. Bind a loopback HTTP listener; the OS picks a free port.
//   3. Compose the provider's authorize URL with our `client_id`,
//      `redirect_uri=http://127.0.0.1:{port}`, the PKCE challenge,
//      and the provider's required offline-access knob.
//   4. `NSWorkspace.shared.open(url)` to launch the system browser.
//   5. Await the listener — when the browser hits us we receive
//      `?code=...&state=...`. Validate `state` matches; if not,
//      reject (someone is replaying an old code).
//   6. POST to the token endpoint with `code` + `code_verifier` to
//      get back `{access_token, refresh_token, expires_in}`.
//   7. Hand the token bundle back to the caller.
//
// Provider-parametrised: each OAuth2 provider gets one `authorize…`
// entry point that runs the full Authorization Code + PKCE dance and
// hands back a token bundle. Adding another provider is one new method
// + one new token-response shape.
//

import AppKit
import DiskJockeyLibrary
import Foundation

public struct OAuthTokens: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: Int?
}

public enum OAuthCoordinatorError: Error, LocalizedError {
    case notConfigured(provider: String)
    case stateMismatch
    case tokenEndpointError(status: Int, body: String)
    case decodeFailed(underlying: Error)
    case browserOpenFailed
    case loopback(OAuthLoopbackError)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let p):
            return "\(p) sign-in isn't configured for this build. Copy DiskJockeyApplication/Resources/OAuthClients.example.json to OAuthClients.json and fill in your \(p) keys."
        case .stateMismatch:
            return "OAuth callback state didn't match — sign-in aborted to prevent CSRF."
        case .tokenEndpointError(let status, let body):
            return "Token exchange failed (HTTP \(status)): \(body)"
        case .decodeFailed(let e):
            return "Couldn't decode the OAuth token response: \(e.localizedDescription)"
        case .browserOpenFailed:
            return "Couldn't open the system browser to complete sign-in."
        case .loopback(let e):
            return e.errorDescription ?? "Loopback listener failed."
        }
    }
}

/// Provider-agnostic OAuth runner. Each `authorize…` entry point
/// owns its provider's quirks (scope strings, offline-access knob,
/// whether the token exchange POSTs a client_secret); the rest of
/// the flow — PKCE, loopback listener, browser open, state guard —
/// is shared.
@MainActor
public final class OAuthCoordinator {
    public static let shared = OAuthCoordinator()
    private init() {}

    /// Run the Dropbox OAuth flow. Resolves with a token bundle
    /// containing the long-lived `refresh_token` (because we ask for
    /// `token_access_type=offline`). Throws on user cancellation,
    /// state mismatch, network failure, or missing config.
    public func authorizeDropbox() async throws -> OAuthTokens {
        guard let cfg = OAuthClientConfig.dropbox else {
            throw OAuthCoordinatorError.notConfigured(provider: "Dropbox")
        }

        let pkce = PKCE()
        let state = UUID().uuidString
        let listener = OAuthLoopbackListener()
        let started: (port: UInt16, callback: Task<OAuthCallback, Error>)
        do {
            started = try await listener.start()
        } catch let e as OAuthLoopbackError {
            throw OAuthCoordinatorError.loopback(e)
        }
        let port = started.port
        let redirectURI = "http://127.0.0.1:\(port)"

        // Dropbox accepts the same scope strings whether the app is
        // App folder or Full Dropbox; the registration's access type
        // gates what the user is consenting *to*. We request the
        // four file scopes plus account_info.read for nice UI labels
        // later. Submit-permission omissions on the developer side
        // surface here as "missing_scope" provider errors.
        let scopes = [
            "files.content.read",
            "files.content.write",
            "files.metadata.read",
            "files.metadata.write",
            "account_info.read",
        ].joined(separator: " ")

        var comps = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: cfg.appKey),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge", value: pkce.codeChallenge),
            .init(name: "code_challenge_method", value: "S256"),
            // Without this Dropbox returns only an access_token and
            // no refresh_token. Mandatory for our use case.
            .init(name: "token_access_type", value: "offline"),
            .init(name: "state", value: state),
            .init(name: "scope", value: scopes),
        ]
        guard let authURL = comps.url else {
            await listener.cancel()
            throw OAuthCoordinatorError.browserOpenFailed
        }

        AppLog.shared.info("OAuth: opening browser for Dropbox authorize, port=\(port)")
        let opened = NSWorkspace.shared.open(authURL)
        if !opened {
            await listener.cancel()
            throw OAuthCoordinatorError.browserOpenFailed
        }

        // Wait for the loopback to capture the redirect.
        let callback: OAuthCallback
        do {
            callback = try await started.callback.value
        } catch let e as OAuthLoopbackError {
            throw OAuthCoordinatorError.loopback(e)
        }

        guard callback.state == state else {
            throw OAuthCoordinatorError.stateMismatch
        }

        // Exchange the code for tokens. PKCE means no client_secret;
        // the verifier is what proves we're the same client that
        // started the flow.
        return try await exchangeDropboxCode(
            cfg: cfg,
            code: callback.code,
            verifier: pkce.codeVerifier,
            redirectURI: redirectURI
        )
    }

    /// Run the Google Drive OAuth flow. Resolves with a token bundle
    /// containing a long-lived `refresh_token` (because we ask
    /// `access_type=offline` + `prompt=consent`).
    ///
    /// Google's desktop-app profile differs from Dropbox in two ways:
    ///   • The token exchange POSTs `client_secret` alongside the PKCE
    ///     verifier. The "secret" is semi-public per Google's own
    ///     guidance — the desktop OAuth profile expects it (see
    ///     docs/google-drive-registration.md §3) — but we still keep
    ///     it out of the on-disk plist by routing it through the
    ///     bundled `OAuthClientConfig`.
    ///   • `prompt=consent` is mandatory: without it Google only
    ///     issues a refresh token on *first* consent, so a returning
    ///     user silently gets only an access token and the mount
    ///     loses offline access on token rotation.
    public func authorizeGDrive() async throws -> OAuthTokens {
        guard let cfg = OAuthClientConfig.gdrive else {
            throw OAuthCoordinatorError.notConfigured(provider: "Google Drive")
        }

        let pkce = PKCE()
        let state = UUID().uuidString
        let listener = OAuthLoopbackListener()
        let started: (port: UInt16, callback: Task<OAuthCallback, Error>)
        do {
            started = try await listener.start()
        } catch let e as OAuthLoopbackError {
            throw OAuthCoordinatorError.loopback(e)
        }
        let port = started.port
        let redirectURI = "http://127.0.0.1:\(port)"

        // Drive scope per the registration's scopeKind, plus the
        // userinfo.email scope so we can label the mount with the
        // user's Google account email post-sign-in (mirrors
        // Dropbox's account_info.read). userinfo.email is non-
        // restricted so it doesn't add to the verification burden.
        let driveScope: String
        switch cfg.scopeKind {
        case .fullDrive:
            driveScope = "https://www.googleapis.com/auth/drive"
        case .driveFile:
            driveScope = "https://www.googleapis.com/auth/drive.file"
        }
        let scopes = [
            driveScope,
            "https://www.googleapis.com/auth/userinfo.email",
        ].joined(separator: " ")

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: cfg.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes),
            .init(name: "access_type", value: "offline"),
            // Without this Google only issues a refresh token on the
            // user's *first* consent — returning users would silently
            // come back with only an access token. Mandatory.
            .init(name: "prompt", value: "consent"),
            .init(name: "code_challenge", value: pkce.codeChallenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        guard let authURL = comps.url else {
            await listener.cancel()
            throw OAuthCoordinatorError.browserOpenFailed
        }

        AppLog.shared.info("OAuth: opening browser for Google Drive authorize, port=\(port)")
        let opened = NSWorkspace.shared.open(authURL)
        if !opened {
            await listener.cancel()
            throw OAuthCoordinatorError.browserOpenFailed
        }

        let callback: OAuthCallback
        do {
            callback = try await started.callback.value
        } catch let e as OAuthLoopbackError {
            throw OAuthCoordinatorError.loopback(e)
        }

        guard callback.state == state else {
            throw OAuthCoordinatorError.stateMismatch
        }

        return try await exchangeGDriveCode(
            cfg: cfg,
            code: callback.code,
            verifier: pkce.codeVerifier,
            redirectURI: redirectURI
        )
    }

    /// Run the Microsoft OneDrive OAuth flow. Resolves with a token
    /// bundle containing a long-lived `refresh_token` (because we ask
    /// for `offline_access`).
    ///
    /// Microsoft's desktop-app profile is a public client: the token
    /// exchange does *not* POST `client_secret` (that's the whole point
    /// of the "Allow public client flows = Yes" toggle in Azure — see
    /// docs/microsoft-onedrive-registration.md §3). PKCE replaces it.
    public func authorizeOneDrive() async throws -> OAuthTokens {
        guard let cfg = OAuthClientConfig.onedrive else {
            throw OAuthCoordinatorError.notConfigured(provider: "OneDrive")
        }

        let pkce = PKCE()
        let state = UUID().uuidString
        let listener = OAuthLoopbackListener()
        let started: (port: UInt16, callback: Task<OAuthCallback, Error>)
        do {
            started = try await listener.start()
        } catch let e as OAuthLoopbackError {
            throw OAuthCoordinatorError.loopback(e)
        }
        let port = started.port
        let redirectURI = "http://localhost:\(port)"

        // Files.ReadWrite covers personal + work/school OneDrive via
        // Microsoft Graph. offline_access is mandatory or the token
        // endpoint won't issue a refresh_token. The driver doesn't
        // need User.Read but we omit it here to keep the consent
        // screen minimal — userPrincipalName is already inside the
        // `id_token` payload if we ever decide to label the mount.
        let scopes = [
            "Files.ReadWrite",
            "offline_access",
        ].joined(separator: " ")

        // `/common` lets both personal Microsoft accounts and any
        // org tenant sign in with the same client_id. Matches the
        // "Accounts in any organizational directory and personal
        // Microsoft accounts" registration option.
        var comps = URLComponents(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: cfg.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_mode", value: "query"),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: pkce.codeChallenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        guard let authURL = comps.url else {
            await listener.cancel()
            throw OAuthCoordinatorError.browserOpenFailed
        }

        AppLog.shared.info("OAuth: opening browser for OneDrive authorize, port=\(port)")
        let opened = NSWorkspace.shared.open(authURL)
        if !opened {
            await listener.cancel()
            throw OAuthCoordinatorError.browserOpenFailed
        }

        let callback: OAuthCallback
        do {
            callback = try await started.callback.value
        } catch let e as OAuthLoopbackError {
            throw OAuthCoordinatorError.loopback(e)
        }

        guard callback.state == state else {
            throw OAuthCoordinatorError.stateMismatch
        }

        return try await exchangeOneDriveCode(
            cfg: cfg,
            code: callback.code,
            verifier: pkce.codeVerifier,
            redirectURI: redirectURI
        )
    }

    private func exchangeOneDriveCode(cfg: OneDriveClientConfig,
                                      code: String,
                                      verifier: String,
                                      redirectURI: String) async throws -> OAuthTokens {
        var req = URLRequest(url: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")
        // Public client — no client_secret. PKCE verifier is what
        // proves we're the same client that started the flow.
        let body = formURLEncoded([
            "grant_type": "authorization_code",
            "client_id": cfg.clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ])
        req.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthCoordinatorError.tokenEndpointError(status: -1, body: "no HTTP response")
        }
        if http.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw OAuthCoordinatorError.tokenEndpointError(status: http.statusCode, body: bodyStr)
        }
        do {
            let decoded = try JSONDecoder().decode(OneDriveTokenResponse.self, from: data)
            return OAuthTokens(
                accessToken: decoded.access_token,
                refreshToken: decoded.refresh_token,
                expiresIn: decoded.expires_in
            )
        } catch {
            throw OAuthCoordinatorError.decodeFailed(underlying: error)
        }
    }

    private func exchangeGDriveCode(cfg: GDriveClientConfig,
                                    code: String,
                                    verifier: String,
                                    redirectURI: String) async throws -> OAuthTokens {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")
        let body = formURLEncoded([
            "grant_type": "authorization_code",
            "client_id": cfg.clientID,
            "client_secret": cfg.clientSecret,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ])
        req.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthCoordinatorError.tokenEndpointError(status: -1, body: "no HTTP response")
        }
        if http.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw OAuthCoordinatorError.tokenEndpointError(status: http.statusCode, body: bodyStr)
        }
        do {
            let decoded = try JSONDecoder().decode(GDriveTokenResponse.self, from: data)
            return OAuthTokens(
                accessToken: decoded.access_token,
                refreshToken: decoded.refresh_token,
                expiresIn: decoded.expires_in
            )
        } catch {
            throw OAuthCoordinatorError.decodeFailed(underlying: error)
        }
    }

    private func exchangeDropboxCode(cfg: DropboxClientConfig,
                                     code: String,
                                     verifier: String,
                                     redirectURI: String) async throws -> OAuthTokens {
        var req = URLRequest(url: URL(string: "https://api.dropbox.com/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")
        let body = formURLEncoded([
            "grant_type": "authorization_code",
            "client_id": cfg.appKey,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ])
        req.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthCoordinatorError.tokenEndpointError(status: -1, body: "no HTTP response")
        }
        if http.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw OAuthCoordinatorError.tokenEndpointError(status: http.statusCode, body: bodyStr)
        }
        do {
            let decoded = try JSONDecoder().decode(DropboxTokenResponse.self, from: data)
            return OAuthTokens(
                accessToken: decoded.access_token,
                refreshToken: decoded.refresh_token,
                expiresIn: decoded.expires_in
            )
        } catch {
            throw OAuthCoordinatorError.decodeFailed(underlying: error)
        }
    }

    private func formURLEncoded(_ pairs: [String: String]) -> String {
        let cs = CharacterSet.urlQueryAllowed
            .subtracting(CharacterSet(charactersIn: "+&="))
        return pairs.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: cs) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: cs) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }
}

/// Wire shape of Dropbox's `/oauth2/token` response when
/// `token_access_type=offline` was requested. `refresh_token` is
/// guaranteed present in this code path; if it's missing the request
/// was missing the offline flag — surface as a decode error so we
/// notice during integration rather than silently storing a
/// short-lived access token.
private struct DropboxTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Int?
}

/// Wire shape of Google's `/token` response when `access_type=offline`
/// and `prompt=consent` were on the authorize call. Both knobs are
/// required to guarantee a `refresh_token` here; if it's absent the
/// authorize URL was missing one of them — surface as a decode error
/// so we catch it during integration rather than silently storing a
/// short-lived access token.
private struct GDriveTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Int?
}

/// Wire shape of Microsoft's `/oauth2/v2.0/token` response when
/// `offline_access` was on the scope list. `refresh_token` is
/// guaranteed present in this code path; if it's missing the
/// authorize call was missing the offline scope — surface as a
/// decode error so we catch it during integration rather than
/// silently storing a short-lived access token.
private struct OneDriveTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Int?
}
