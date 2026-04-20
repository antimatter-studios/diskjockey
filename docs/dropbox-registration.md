# Dropbox App Registration

DiskJockey's Dropbox driver uses the Dropbox HTTP API with OAuth2. You (the developer) register the app **once** in the Dropbox App Console; end users sign in and grant consent the first time they add a Dropbox mount.

This doc covers the developer-side registration. User-facing sign-in is handled by the app.

---

## 1. What lives where

| Credential         | Who holds it   | How it's used                                                   |
|--------------------|----------------|-----------------------------------------------------------------|
| `App key`          | Developer      | Public — baked into the DiskJockey binary. Dropbox's `client_id`. |
| `App secret`       | **Not used**   | Public clients must not ship secrets. PKCE replaces it.         |
| `refresh_token`    | End user       | Issued per user after consent. Stored in the user's macOS keychain. |
| `access_token`     | End user       | Short-lived (≈4 h). Derived from `refresh_token` on demand.     |

> **Current driver note:** the existing driver in `vendor/go-networkfs/dropbox/dropbox.go` only accepts a long-lived `access_token` config key. To use refresh tokens properly (which is what Dropbox now recommends — long-lived tokens are deprecated for new apps), the driver needs updating to accept `app_key` + `refresh_token` and do OAuth2 refresh like the OneDrive/GDrive drivers. Track this as a follow-up.

---

## 2. Register the app in Dropbox (one-time, developer)

1. Go to <https://www.dropbox.com/developers/apps> → **Create app**.
2. **Choose an API:** *Scoped access* (the modern API — legacy "Full Dropbox" app type is deprecated).
3. **Choose the type of access you need:**
   - **App folder** — DiskJockey is sandboxed to `/Apps/DiskJockey/` inside the user's Dropbox. Simpler, no verification needed for distribution.
   - **Full Dropbox** — access to the user's entire Dropbox. Requires Dropbox's app review to move to Production status (see §6).
4. **Name your app:** must be **globally unique across all Dropbox apps**. Try `DiskJockey` first; if taken, `DiskJockey-<yourhandle>`.
5. Click **Create app**. You'll land on the app's Settings page.
6. Copy the **App key** — this is our `client_id`.

---

## 3. Configure it as a public client

1. On the app's **Settings** tab, scroll to **OAuth 2**.
2. **Redirect URIs** — add one of:
   - `http://localhost` (loopback flow; DiskJockey spins up a temporary HTTP listener).
   - A custom scheme like `diskjockey://auth` declared in `Info.plist`.
3. **Allow implicit grant:** Disable.
4. **PKCE required:** Dropbox supports PKCE for public clients. We use it — no `client_secret` needed.

**Do not** use the **App secret** shown on the Settings page. Treat it as if it doesn't exist for a distributed desktop app.

---

## 4. Configure the required permissions

1. Open the **Permissions** tab.
2. Enable:
   - `files.content.read` — read file content.
   - `files.content.write` — write/modify files.
   - `files.metadata.read` — list directories, stat.
   - `files.metadata.write` — rename, delete (also needed for move).
   - `account_info.read` — (optional) display the account email in DiskJockey's UI.
3. Click **Submit** at the bottom to save. **Scopes only take effect after Submit** — easy to miss.

---

## 5. End-user sign-in flow (what DiskJockey does at runtime)

Reference for implementation — not a dev task here.

1. User clicks **Add Dropbox mount** → app generates a PKCE `code_verifier` + `code_challenge`.
2. App opens the system browser to:
   ```
   https://www.dropbox.com/oauth2/authorize
     ?client_id={app_key}
     &response_type=code
     &redirect_uri=http://localhost:{port}
     &code_challenge={code_challenge}
     &code_challenge_method=S256
     &token_access_type=offline
   ```
   **`token_access_type=offline` is mandatory** — without it Dropbox returns only a short-lived access token and no refresh token.
3. User signs in, consents. Dropbox redirects to `http://localhost:{port}/?code={auth_code}`.
4. App POSTs to `https://api.dropboxapi.com/oauth2/token`:
   ```
   grant_type=authorization_code
   &client_id={app_key}
   &code={auth_code}
   &redirect_uri=http://localhost:{port}
   &code_verifier={code_verifier}
   ```
5. Response contains `access_token`, `refresh_token`, `expires_in` (typically 14400 s). Persist `refresh_token` in the keychain.
6. Send `{app_key, refresh_token}` to the Go backend as the mount config. Driver refreshes access tokens on demand.

---

## 6. Development vs Production (app review)

Dropbox gates distribution with an app-status flag:

- **Development status** (default) — app can be used by up to **500 users**. Only the developer account can create files until users are individually added, though in practice any user who signs in can auth. 500-user ceiling applies.
- **Production status** — unlimited users. Requires Dropbox to review the app.

To apply for Production:

1. App Console → your app → **Settings** → **Status** → **Apply for Production**.
2. Dropbox asks for screenshots, a description of how DiskJockey uses the scopes, and a working demo.
3. Review time: days to weeks.

**App folder** apps are usually fast-tracked. **Full Dropbox** apps get more scrutiny.

Skip this until you're ready to ship to more than 500 users.

---

## 7. Credentials in the driver config

Target config shape once the driver is updated to refresh-token auth:

```
client_id      - required, developer-provided, public (Dropbox App key)
client_secret  - leave empty for public-client / PKCE flow
refresh_token  - required, per-user, from the flow above
```

Current driver (not yet updated):

```
access_token   - required, long-lived (deprecated style)
```

---

## 8. Rotating / revoking

- **User revokes:** user can disconnect DiskJockey at <https://www.dropbox.com/account/connected_apps>. Refresh then fails; DiskJockey prompts for re-sign-in.
- **Developer rotates app:** App Console can **reset the App key**. Doing so invalidates every user's refresh token. Avoid unless the key is compromised.

---

## 9. Reference

- Dropbox OAuth guide: <https://developers.dropbox.com/oauth-guide>
- PKCE flow spec (for public apps): <https://www.rfc-editor.org/rfc/rfc7636>
- Scopes reference: <https://developers.dropbox.com/oauth-guide#dropbox-api-permissions>
- API endpoints: <https://www.dropbox.com/developers/documentation/http/documentation>
