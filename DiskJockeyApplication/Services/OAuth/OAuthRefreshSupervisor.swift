//
// OAuthRefreshSupervisor.swift — auto-recovery for dead OAuth refresh
// tokens across every cloud-storage provider that uses one (Dropbox,
// Google Drive, OneDrive).
//
// Why this exists:
//   • A `refresh_token` issued by Dropbox/Google/Microsoft can die for
//     reasons outside our control — user revokes access, password
//     change, 7-day inactivity in Google's testing-mode app, Microsoft
//     conditional-access policy, etc. The OAuth providers all surface
//     the same wire signal (HTTP 400 + body `error":"invalid_grant"`).
//   • Without this supervisor, the user would have to navigate into
//     mount settings and click "Sign in again" by hand. Per the
//     project's user intent, this should be transparent.
//
// Wire signal:
//   The Go drivers (gdrive, onedrive, dropbox) prefix their error
//   message with `oauth_reauth_required:` when they detect
//   `invalid_grant` from the token endpoint. The FileProvider extension
//   funnels every driver error through `mount.error` events, which
//   `DirectMountRegistry` routes to us. We also fall back to a
//   substring match on `invalid_grant` / `invalid refresh token` for
//   defence-in-depth.
//
// Recovery sequence:
//   1. Identify the OAuth provider from the mount's StoredMountConfig.
//   2. Dedupe — drop the trigger if a re-auth is already in flight for
//      this mount, so a flurry of Finder ops doesn't open five browser
//      windows.
//   3. Run `OAuthCoordinator.authorizeXxx()`. The user sees a browser
//      pop up with the familiar consent screen — same flow as initial
//      sign-in.
//   4. Persist the new refresh_token to the shared keychain, and the
//      fresh access_token into the mount config plist (so the next
//      `Mount` skips the validate-then-refresh dance).
//   5. Cycle the FileProvider domain (`unmountDomain` →
//      `mountDomain`) so the extension respawns with the new
//      credentials cached at init.
//   6. Clear the red error banner.
//
// On user cancellation, OAuth-config-missing, or any other failure, we
// log and leave the banner up — that's the existing "click to
// re-auth" affordance, so the user can still recover manually.
//

import Foundation
import FileProvider
import DiskJockeyLibrary

@MainActor
public final class OAuthRefreshSupervisor {
    private weak var registry: DirectMountRegistry?
    private let configStore: MountConfigStore
    private let keychain: MountKeychain

    /// Domain IDs with a re-auth currently in flight. Prevents the
    /// browser opening multiple times when several Finder ops fail
    /// in parallel against the same dead refresh token.
    private var inFlight: Set<String> = []

    public init(
        registry: DirectMountRegistry,
        configStore: MountConfigStore = MountConfigStore(),
        keychain: MountKeychain = MountKeychain()
    ) {
        self.registry = registry
        self.configStore = configStore
        self.keychain = keychain
    }

    /// Entry point — DirectMountRegistry calls this whenever a
    /// `mount.error` event is recorded. Cheap: returns immediately if
    /// the error isn't an OAuth re-auth signal, or a re-auth is
    /// already running for this mount.
    public func handleMountError(domainID: String, error: MountConnectionError) {
        guard Self.isReauthSignal(error) else { return }
        guard !inFlight.contains(domainID) else {
            AppLog.shared.info("oauth-reauth: \(domainID) already in flight; skipping")
            return
        }
        guard let registry, let mount = registry.mount(withID: UUID(uuidString: domainID) ?? UUID()) else {
            return
        }
        guard let provider = Self.provider(for: mount.config) else {
            return
        }
        inFlight.insert(domainID)
        AppLog.shared.info("oauth-reauth: starting for \(mount.displayName) provider=\(provider)")
        Task { @MainActor [weak self] in
            await self?.runReauth(mount: mount, provider: provider)
            self?.inFlight.remove(domainID)
        }
    }

    private func runReauth(mount: DirectMount, provider: OAuthProvider) async {
        guard let registry else { return }
        let tokens: OAuthTokens
        do {
            switch provider {
            case .dropbox:
                tokens = try await OAuthCoordinator.shared.authorizeDropbox()
            case .gdrive:
                tokens = try await OAuthCoordinator.shared.authorizeGDrive()
            case .onedrive:
                tokens = try await OAuthCoordinator.shared.authorizeOneDrive()
            }
        } catch {
            AppLog.shared.error("oauth-reauth: authorize failed for \(mount.displayName): \(error)")
            return
        }

        do {
            try keychain.save(password: tokens.refreshToken, domainID: mount.domainID)
        } catch {
            AppLog.shared.error("oauth-reauth: keychain save failed for \(mount.displayName): \(error)")
            return
        }

        if let updated = Self.configWithFreshAccessToken(mount.config, accessToken: tokens.accessToken) {
            do {
                try configStore.save(updated, domainID: mount.domainID)
            } catch {
                AppLog.shared.error("oauth-reauth: config save failed for \(mount.displayName): \(error)")
                // Non-fatal: the new refresh_token is in the keychain;
                // the next mount will re-derive an access_token from it.
            }
        }

        do {
            try await registry.unmountDomain(mount)
            try await registry.mountDomain(mount)
            AppLog.shared.info("oauth-reauth: recovered \(mount.displayName); domain cycled")
        } catch {
            // Cycling the domain is best-effort. Even if it fails, the
            // updated keychain entry is in place; the next FileProvider
            // op will re-mount with the fresh credentials.
            AppLog.shared.error("oauth-reauth: domain cycle failed for \(mount.displayName): \(error)")
        }

        registry.dismissConnectionError(forDomainID: mount.domainID)
    }

    // MARK: - Pure helpers

    /// Decide whether a `mount.error` represents a dead OAuth refresh
    /// token. Both the structured marker (`oauth_reauth_required`,
    /// emitted by the Go drivers) and the raw provider-level signals
    /// (`invalid_grant`, `invalid refresh token`) qualify — we want
    /// defence-in-depth so a future driver that forgets the marker
    /// still triggers recovery.
    static func isReauthSignal(_ err: MountConnectionError) -> Bool {
        let s = err.detail.lowercased()
        return s.contains("oauth_reauth_required")
            || s.contains("invalid_grant")
            || s.contains("invalid refresh token")
    }

    enum OAuthProvider: String { case dropbox, gdrive, onedrive }

    static func provider(for config: StoredMountConfig) -> OAuthProvider? {
        switch config {
        case .dropbox:  return .dropbox
        case .gdrive:   return .gdrive
        case .onedrive: return .onedrive
        default:        return nil
        }
    }

    /// Build a new StoredMountConfig with the freshly-issued
    /// access_token cached, preserving every other field. Returns nil
    /// for non-OAuth schemes (no-op caller).
    static func configWithFreshAccessToken(
        _ config: StoredMountConfig, accessToken: String
    ) -> StoredMountConfig? {
        switch config {
        case .gdrive(let c):
            return .gdrive(GDriveMountConfig(
                clientID: c.clientID,
                clientSecret: c.clientSecret,
                cachedAccessToken: accessToken,
                accountLabel: c.accountLabel
            ))
        case .onedrive(let c):
            return .onedrive(OneDriveMountConfig(
                clientID: c.clientID,
                clientSecret: c.clientSecret,
                cachedAccessToken: accessToken,
                accountLabel: c.accountLabel
            ))
        case .dropbox:
            // Dropbox's mount config doesn't carry an access_token —
            // the oauth2 lib refreshes lazily off the keychain'd
            // refresh_token, so there's nothing to update here.
            return nil
        default:
            return nil
        }
    }
}
