# Microsoft OneDrive App Registration

DiskJockey's OneDrive driver uses Microsoft Graph via OAuth2. You (the developer) register the app **once**; end users then sign in and grant consent the first time they add a OneDrive mount.

This doc covers the developer-side registration. User-facing sign-in is handled by the app.

---

## 1. What lives where

| Credential         | Who holds it   | How it's used                                                |
|--------------------|----------------|--------------------------------------------------------------|
| `client_id`        | Developer      | Public — baked into the DiskJockey binary. Identifies the app. |
| `client_secret`    | **Not used**   | Public clients (desktop apps) must not ship secrets. We use PKCE instead. |
| `refresh_token`    | End user       | Issued per user after consent. Stored in the user's macOS keychain. |
| `access_token`     | End user       | Short-lived (≈1 h). Derived from `refresh_token` on demand.  |

The driver config (`DiskJockeyLibrary/NetworkFS/OneDriveMountConfig.swift` — to be added) persists `client_id` + `refresh_token` per mount and sends them to the Go backend. `client_secret` stays empty.

---

## 2. Register the app in Azure (one-time, developer)

1. Go to <https://entra.microsoft.com> → **Identity** → **Applications** → **App registrations** → **New registration**.
2. **Name:** `DiskJockey` (user-visible on the consent screen).
3. **Supported account types:** *Accounts in any organizational directory and personal Microsoft accounts*. This lets both `@outlook.com` users and work/school OneDrive users sign in with the same `client_id`.
4. **Redirect URI:** pick one of:
   - **Public client / native** → `http://localhost` (loopback flow; DiskJockey spins up a temporary local HTTP listener for the callback). Simplest for desktop apps.
   - *Or* a custom scheme like `diskjockey://auth` registered as a **Mobile and desktop** redirect URI and declared in `Info.plist` as a `CFBundleURLSchemes` entry.
5. Click **Register**. Copy the **Application (client) ID** — this is our `client_id`.

---

## 3. Configure it as a public client

1. In the registration, open **Authentication**.
2. Under **Advanced settings** → **Allow public client flows** → set **Yes**.
3. Verify the redirect URI from step 2.4 is listed under **Mobile and desktop applications**.
4. Save.

**Do not** create a client secret under **Certificates & secrets**. A secret embedded in a distributed binary is not a secret. PKCE replaces it.

---

## 4. Request the delegated permissions

1. Open **API permissions** → **Add a permission** → **Microsoft Graph** → **Delegated permissions**.
2. Add:
   - `Files.ReadWrite` — read/write the user's files.
   - `offline_access` — required to receive a `refresh_token`. Without it, the access token expires in an hour and the user has to sign in again.
3. These are user-consentable, so **no admin consent is required** for personal accounts. Work/school tenants may have policies that require admin approval — out of our control.
4. Save.

---

## 5. (Optional) Publisher verification

Unverified apps show an "unverified app" warning on the consent screen for work/school accounts (personal OneDrive is unaffected). To remove the warning:

1. Enroll in the Microsoft Partner Network (MPN) — free.
2. Associate the MPN ID with the app registration under **Branding & properties** → **Publisher domain** → **Verify**.

Skip this for initial development. Revisit before shipping to non-personal-account users.

---

## 6. End-user sign-in flow (what DiskJockey does at runtime)

Reference for implementation — not a dev task here.

1. User clicks **Add OneDrive mount** → app generates a PKCE `code_verifier` + `code_challenge`.
2. App opens the system browser to:
   ```
   https://login.microsoftonline.com/common/oauth2/v2.0/authorize
     ?client_id={client_id}
     &response_type=code
     &redirect_uri=http://localhost:{port}
     &response_mode=query
     &scope=Files.ReadWrite%20offline_access
     &code_challenge={code_challenge}
     &code_challenge_method=S256
   ```
3. User signs in, consents. Microsoft redirects to `http://localhost:{port}/?code={auth_code}`.
4. App POSTs to `https://login.microsoftonline.com/common/oauth2/v2.0/token`:
   ```
   grant_type=authorization_code
   &client_id={client_id}
   &code={auth_code}
   &redirect_uri=http://localhost:{port}
   &code_verifier={code_verifier}
   ```
5. Response contains `access_token`, `refresh_token`, `expires_in`. Persist the `refresh_token` in the keychain.
6. Send `{client_id, refresh_token}` to the Go backend as the mount config. The driver handles refresh itself from there.

---

## 7. Credentials in the driver config

The Go driver (`vendor/go-networkfs/onedrive/onedrive.go`) accepts:

```
client_id      - required, developer-provided, public
client_secret  - leave empty for public-client / PKCE flow
refresh_token  - required, per-user, from the flow above
```

The driver handles proactive refresh (using `expires_in`), reactive refresh on HTTP 401, and refresh-token rotation (Microsoft may issue a new `refresh_token` with each refresh response — the driver picks up the new one automatically).

---

## 8. Rotating / revoking

- **User revokes:** user can remove consent at <https://myaccount.microsoft.com/consent>. Refresh then fails; driver surfaces the error and DiskJockey prompts the user to re-sign-in.
- **Developer rotates app:** creating a new `client_id` invalidates every existing user's refresh token. Avoid unless necessary (e.g., compromise). Shipping a new `client_id` requires every user to re-consent on next launch.

---

## 9. Reference

- Microsoft identity platform auth code + PKCE: <https://learn.microsoft.com/entra/identity-platform/v2-oauth2-auth-code-flow>
- Graph Files API: <https://learn.microsoft.com/graph/api/resources/driveitem>
- Permissions reference: <https://learn.microsoft.com/graph/permissions-reference#files-permissions>
