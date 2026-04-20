# OAuth Flow — Implementation Plan

**Status:** Not yet implemented. Placeholder doc so we don't forget.

The direct-mount Go drivers for Google Drive, OneDrive, and Dropbox all accept a `refresh_token` (Dropbox: `access_token`) as input. Acquiring that token is the desktop app's job — this doc is the plan for that work.

For the developer-side OAuth client registration (creating the app in Google Cloud / Azure / Dropbox console, picking scopes, verification), see the per-provider docs already in this folder:

- [google-drive-registration.md](./google-drive-registration.md)
- [microsoft-onedrive-registration.md](./microsoft-onedrive-registration.md)
- [dropbox-registration.md](./dropbox-registration.md)

This doc is **app-side implementation only**.

---

## Stopgap (ships now, alongside backend deprecation)

Until the real flow is built, the `AddMountView` forms for `gdrive` / `onedrive` / `dropbox` expose:

- `client_id` — TextField
- `client_secret` — TextField (SecureField for OneDrive/Dropbox; visible for gdrive because Google's desktop profile treats it as semi-public)
- `refresh_token` / `access_token` — SecureField, user pastes it

Users obtain the token out-of-band (`curl` against the token endpoint, browser dev console, or a one-off CLI script). Ugly, but unblocks the direct-mount path without blocking on the OAuth work.

The fields map 1:1 to `GDriveMountConfig`, `OneDriveMountConfig`, `DropboxMountConfig`. When the real flow lands, only the form UI changes — the stored config shape stays identical.

---

## Target flow (to be built)

All three providers use **OAuth2 Authorization Code + PKCE** with a loopback redirect. The flow is provider-agnostic enough that we should build it once and parameterize per provider.

### 1. User clicks "Add Google Drive mount"

`AddMountView` calls something like:

```swift
let tokens = try await OAuthCoordinator.shared.authorize(
    provider: .gdrive,
    clientID: GDriveClientConfig.clientID,
    clientSecret: GDriveClientConfig.clientSecret,
    scopes: ["https://www.googleapis.com/auth/drive"]
)
```

Hands back `{ accessToken, refreshToken, expiresAt }`. The rest of the AddMount flow uses `tokens.refreshToken` as the `password` argument to `DirectMountRegistry.createGDriveMount(...)`.

### 2. Start a loopback HTTP server

- Bind to `127.0.0.1:0` (OS picks a free port).
- Use `Network.framework` (`NWListener` with `.tcp` + a minimal HTTP parser) or `swift-nio`. `NWListener` is enough; no need to pull NIO for one request.
- Listener handles exactly one GET to `/?code=...&state=...`, responds with a tiny HTML "You can close this window", then shuts down.
- Timeout after ~5 minutes.

### 3. Build the authorization URL and open the browser

Generate PKCE:

```swift
let codeVerifier = Data.random(64).base64URLEncoded
let codeChallenge = SHA256.hash(codeVerifier).base64URLEncoded
let state = UUID().uuidString
```

Compose the URL per provider:

| Provider  | Authorize endpoint | Key params |
|-----------|--------------------|------------|
| gdrive    | `https://accounts.google.com/o/oauth2/v2/auth` | `access_type=offline`, `prompt=consent` (so refresh_token is issued every time — Google is stingy otherwise) |
| onedrive  | `https://login.microsoftonline.com/common/oauth2/v2.0/authorize` | scope includes `offline_access` (required for refresh_token) |
| dropbox   | `https://www.dropbox.com/oauth2/authorize` | `token_access_type=offline` |

Common params: `client_id`, `response_type=code`, `redirect_uri=http://127.0.0.1:{port}`, `scope`, `code_challenge`, `code_challenge_method=S256`, `state`.

Open with `NSWorkspace.shared.open(url)`.

### 4. Capture the callback

The loopback listener receives `GET /?code={authCode}&state={state}`. Validate `state` matches what we sent (CSRF guard). Close the listener.

If the user denies consent, the callback is `?error=access_denied` — surface as a typed error and abort cleanly.

### 5. Exchange the code for tokens

POST to the provider's token endpoint:

| Provider  | Token endpoint |
|-----------|----------------|
| gdrive    | `https://oauth2.googleapis.com/token` |
| onedrive  | `https://login.microsoftonline.com/common/oauth2/v2.0/token` |
| dropbox   | `https://api.dropbox.com/oauth2/token` |

Body (`application/x-www-form-urlencoded`):

```
grant_type=authorization_code
&client_id={clientID}
&client_secret={clientSecret}          # omit for OneDrive public clients
&code={authCode}
&redirect_uri=http://127.0.0.1:{port}
&code_verifier={codeVerifier}
```

Parse `{ access_token, refresh_token, expires_in }`. Done.

### 6. Hand off to DirectMountRegistry

The refresh token goes to `MountKeychain` via the `createGDriveMount(...)` / `createOneDriveMount(...)` / `createDropboxMount(...)` factories. `cachedAccessToken` can be stashed in the `*MountConfig` so the driver doesn't have to refresh on first use.

---

## Where the client credentials live

`client_id` and `client_secret` are developer-held, baked into the app binary. Recommended shape:

```
DiskJockeyLibrary/OAuth/
  OAuthProvider.swift         // enum: gdrive, onedrive, dropbox
  OAuthClientConfig.swift     // per-provider client_id/secret constants
  OAuthCoordinator.swift      // @MainActor, owns the flow
  OAuthLoopbackListener.swift // NWListener wrapper, one-shot
  PKCE.swift                  // codeVerifier/challenge helpers
```

Keep the constants in a single file that's `.gitignore`-d in a fork-friendly way if we decide to ship without committing our keys — but the keys are public-ish per the registration docs, so committing them is fine.

---

## Edge cases to handle

- **User closes the browser tab without consenting.** Loopback listener times out → surface `OAuthError.timeout`, cancel from the AddMount form.
- **`state` mismatch.** Reject; don't exchange the code.
- **Google test-mode refresh-token expiry (7 days).** Driver starts returning `invalid_grant`; app should re-open OAuth on the next mount. Track which mount belongs to which provider so we know who to re-auth.
- **OneDrive token theft window.** Microsoft issues refresh tokens that *also* rotate on each use (optional per app config); if we enable rotation, we must persist the new one returned in every refresh response, not just the first one. Decide this when registering the Azure app.
- **Keychain access during re-auth.** `MountKeychain.save` is an upsert — re-auth just overwrites the old refresh token cleanly.

---

## Rough effort estimate

- PKCE + loopback listener + URL builder + token exchange: ~1 day.
- Wiring into AddMountView with a "Sign in to Google Drive" button that swaps for "Signed in as foo@example.com": ~½ day per provider form.
- Handling expired refresh tokens (re-auth prompt from an already-mounted volume): ~½ day.

Total: ~3 days of focused work. Tracked here so it doesn't get lost.
