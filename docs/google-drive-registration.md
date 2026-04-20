# Google Drive App Registration

DiskJockey's Google Drive driver uses the Drive v3 REST API with OAuth2. You (the developer) register the app **once** in Google Cloud Console; end users sign in and grant consent the first time they add a Google Drive mount.

This doc covers the developer-side registration. User-facing sign-in is handled by the app.

Google's process is heavier than Microsoft's or Dropbox's because Drive's full-access scope is classified **restricted** and triggers a security review for distribution beyond test users.

---

## 1. What lives where

| Credential         | Who holds it     | How it's used                                                    |
|--------------------|------------------|------------------------------------------------------------------|
| `client_id`        | Developer        | Public — baked into the DiskJockey binary.                       |
| `client_secret`    | Developer        | Historically ships with desktop-app OAuth clients. Not truly secret, but Google's flow expects it. See §3. |
| `refresh_token`    | End user         | Issued per user after consent. Stored in the user's macOS keychain. |
| `access_token`     | End user         | Short-lived (≈1 h). Derived from `refresh_token` on demand.      |

The current driver (`vendor/go-networkfs/gdrive/gdrive.go`) already uses this shape: `client_id` + `client_secret` + `refresh_token`.

---

## 2. Create a Google Cloud project (one-time, developer)

1. Go to <https://console.cloud.google.com> → project dropdown → **New project**.
2. **Project name:** `DiskJockey`. (Organization optional.)
3. **Create**. Wait a few seconds; switch to the new project.

---

## 3. Enable the Drive API

1. **APIs & Services** → **Library** → search "Google Drive API" → **Enable**.

---

## 4. Configure the OAuth consent screen

1. **APIs & Services** → **OAuth consent screen**.
2. **User type:**
   - **External** — any Google account can sign in. Requires verification for restricted scopes (see §7). This is what you want for a distributed app.
   - **Internal** — only Google Workspace users in your org. No verification needed, but also useless for a public macOS app.
3. Fill in:
   - **App name:** `DiskJockey` (shown on the consent screen).
   - **User support email**, **Developer contact email**.
   - **App logo** (optional but required for verification later).
   - **Application home page**, **Privacy policy URL**, **Terms of service URL** — required for verification.
   - **Authorized domains** — the domain hosting your privacy policy / home page.
4. **Scopes** page → **Add or remove scopes** → add:
   - `https://www.googleapis.com/auth/drive` — full read/write to all of the user's Drive files. **This is a restricted scope.**
   - *Or, less invasive:* `https://www.googleapis.com/auth/drive.file` — access only files the app creates or the user explicitly opens with the app. **Not restricted**, no verification required, but DiskJockey would only see its own files — probably not what you want for a general-purpose mount.
5. **Test users** page → add your own Google account and anyone helping you test. **Up to 100 test users.** Until verification completes, only these accounts can sign in.
6. Save.

---

## 5. Create the OAuth client credentials

1. **APIs & Services** → **Credentials** → **Create credentials** → **OAuth client ID**.
2. **Application type:** **Desktop app**. (Picks up the right redirect URI behavior — Google's desktop profile supports `http://localhost` loopback.)
3. **Name:** `DiskJockey Desktop`.
4. **Create**. A dialog shows **Client ID** and **Client secret**. Copy both.
5. You can also download the JSON file (`client_secret_XXX.json`) for safekeeping.

**About the "secret":** Google's desktop-app OAuth profile ships a client_secret with every app that distributes a binary. Security researchers extract these routinely. Google knows this — the effective security model is that `client_id + client_secret` identifies the app (for rate-limiting and brand display), not the user. Treat it as public-ish. Do not reuse it as an API key.

---

## 6. End-user sign-in flow (what DiskJockey does at runtime)

Reference for implementation — not a dev task here.

1. User clicks **Add Google Drive mount** → app generates a PKCE `code_verifier` + `code_challenge`.
2. App opens the system browser to:
   ```
   https://accounts.google.com/o/oauth2/v2/auth
     ?client_id={client_id}
     &response_type=code
     &redirect_uri=http://localhost:{port}
     &scope=https%3A//www.googleapis.com/auth/drive
     &access_type=offline
     &prompt=consent
     &code_challenge={code_challenge}
     &code_challenge_method=S256
   ```
   - `access_type=offline` — required to receive a refresh token.
   - `prompt=consent` — **forces the consent screen every time**, which guarantees a refresh token is issued. Without it, returning users get only an access token (Google only issues a refresh token on first consent), and the app silently loses offline access when tokens rotate.
3. User signs in, consents. Google redirects to `http://localhost:{port}/?code={auth_code}`.
4. App POSTs to `https://oauth2.googleapis.com/token`:
   ```
   grant_type=authorization_code
   &client_id={client_id}
   &client_secret={client_secret}
   &code={auth_code}
   &redirect_uri=http://localhost:{port}
   &code_verifier={code_verifier}
   ```
5. Response contains `access_token`, `refresh_token`, `expires_in` (typically 3599 s). Persist `refresh_token` in the keychain.
6. Send `{client_id, client_secret, refresh_token}` to the Go backend as the mount config. Driver refreshes access tokens on demand (see `gdrive.go:doRefresh`).

---

## 7. Verification (required for distribution with `drive` scope)

The `https://www.googleapis.com/auth/drive` scope is classified **restricted**. Until Google verifies the app:

- Only the **test users** listed in §4.5 can sign in.
- Other users see a red *"Access blocked: DiskJockey has not completed the Google verification process"* screen.
- 100-test-user cap.

To distribute broadly, submit for verification:

1. OAuth consent screen → **Publish app** → moves from **Testing** to **In production**.
2. **Submit for verification** — required because of the restricted scope.
3. Google requires:
   - **Brand verification** — domain ownership for the authorized domains.
   - **Homepage and privacy policy** at those domains, clearly explaining data use.
   - **Scope justification** — written explanation of *why* DiskJockey needs full Drive access (e.g. "we mount Drive as a filesystem, so we must read and write arbitrary user-chosen files").
   - **Demo video** — screen recording of the app's OAuth flow and data usage.
   - **CASA security assessment** — third-party security audit by a Google-approved lab. Required for restricted scopes. **Paid**; several thousand USD, several weeks.
4. Review time: weeks to months. Iteration typical.

**If you can get away with `drive.file` instead of `drive`:**
- No verification needed.
- No CASA audit.
- But DiskJockey can only see files it created/opened, which probably breaks the "mount my whole Drive" use case.

Realistically: start with `drive.file` and a small test-user list for development; budget for the CASA process before shipping a `drive`-scoped build to the public.

---

## 8. Credentials in the driver config

```
client_id      - required, developer-provided
client_secret  - required, developer-provided (Google desktop-app profile)
refresh_token  - required, per-user, from the flow above
```

Matches the existing driver's `Mount()` config keys in `vendor/go-networkfs/gdrive/gdrive.go`.

---

## 9. Rotating / revoking

- **User revokes:** user can remove DiskJockey at <https://myaccount.google.com/permissions>. Refresh then fails with `invalid_grant`; DiskJockey prompts for re-sign-in.
- **Refresh token expiry:** Google refresh tokens issued to **Testing-mode** apps expire after **7 days**. In **Production** mode they're long-lived. This catches developers off guard — test builds lose auth weekly until the app is published.
- **Developer rotates client:** Credentials page can revoke/recreate the OAuth client. Invalidates every user's refresh token. Avoid unless compromised.

---

## 10. Reference

- Google OAuth 2.0 for Desktop Apps: <https://developers.google.com/identity/protocols/oauth2/native-app>
- Drive API scopes reference: <https://developers.google.com/drive/api/guides/api-specific-auth>
- Verification FAQ: <https://support.google.com/cloud/answer/9110914>
- CASA security assessment: <https://appdefensealliance.dev/casa>
