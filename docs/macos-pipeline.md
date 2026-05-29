# macOS code signing, notarization, and App Store submission

Two release paths, pick per build:

| Path | Use for | Cert | Distribution |
|---|---|---|---|
| **Developer ID + notarize** | Local release runs, GitHub Releases, direct DMG | Developer ID Application | Any Mac, Gatekeeper-clean |
| **Mac App Store** | App Store listing | 3rd Party Mac Developer Application + Installer | App Store Connect |

Same Apple Developer Program account covers both. Team ID: `43UMKXZ8P4` (`Chris Thomas`).

DiskJockey ships 4 signed bundles — all must be signed by the same team:

- `com.antimatterstudios.diskjockey` — main app
- `com.antimatterstudios.diskjockey.ext4` — FSKit extension (embedded)
- `com.antimatterstudios.diskjockey.ntfs` — FSKit extension (embedded)
- `com.antimatterstudios.diskjockey.fileprovider` — File Provider extension (embedded)

Each extension has its own `.entitlements` already configured for sandbox.

---

## Path A — Developer ID + notarize (do this first)

This is what you want for daily release-mode dev runs.

### One-time setup

1. **Apple Developer Program** membership ($99/yr).
2. **Developer ID Application** cert:
   - Xcode → Settings → Accounts → Manage Certificates → `+` → Developer ID Application
   - Verify in Keychain Access: identity string is `Developer ID Application: Chris Thomas (43UMKXZ8P4)`
3. **App Store Connect API key** for `notarytool` (scoped, revocable, no 2FA):
   - appstoreconnect.apple.com → Users and Access → Integrations → Keys → `+`
   - Role: **Developer**
   - Download the `.p8` once (cannot re-download). Note **Key ID** + **Issuer ID**.
   - Store at `~/.private_keys/AuthKey_<KEYID>.p8` (notarytool default search path).

### Local build script

Create `scripts/release-build.sh`:

```sh
#!/usr/bin/env bash
set -euo pipefail

SCHEME="DiskJockey"
CONFIG="Release"
BUILD_DIR="$(pwd)/build/release"
ARCHIVE="$BUILD_DIR/DiskJockey.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
TEAM_ID="43UMKXZ8P4"
API_KEY_ID="${APPLE_API_KEY_ID:?set in env}"
API_ISSUER="${APPLE_API_ISSUER:?set in env}"

mkdir -p "$BUILD_DIR"

# 1. Archive (signs all 4 bundles via project settings)
xcodebuild -project DiskJockey.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -archivePath "$ARCHIVE" \
  -destination "generic/platform=macOS" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  archive

# 2. Export as Developer ID
cat > "$BUILD_DIR/export-developer-id.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/export-developer-id.plist" \
  -allowProvisioningUpdates

APP="$EXPORT_DIR/DiskJockey.app"

# 3. Notarize (zip first — notarytool wants zip/dmg/pkg)
ZIP="$BUILD_DIR/DiskJockey.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

xcrun notarytool submit "$ZIP" \
  --key "$HOME/.private_keys/AuthKey_${API_KEY_ID}.p8" \
  --key-id "$API_KEY_ID" \
  --issuer "$API_ISSUER" \
  --wait

# 4. Staple ticket into the .app (so it works offline)
xcrun stapler staple "$APP"

# 5. Verify
spctl -a -vvv -t exec "$APP"
codesign --verify --deep --strict --verbose=4 "$APP"
stapler validate "$APP"

echo "OK → $APP"
```

Run with:

```sh
export APPLE_API_KEY_ID=XXXXXXXXXX
export APPLE_API_ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
./scripts/release-build.sh
```

First run will be slow (notary submit takes 2–10 min). Subsequent rebuilds reuse the cached archive deltas.

### Why staple?

Stapling embeds the notarization ticket into the bundle so Gatekeeper accepts it offline. Without stapling, the first launch needs internet to fetch the ticket from Apple.

### Hardened runtime / entitlements

Xcode enables hardened runtime (`--options runtime`) automatically for Developer ID. Your existing entitlements files already handle sandbox; no edit needed for Path A.

If notarization rejects with "hardened runtime missing", check `ENABLE_HARDENED_RUNTIME = YES` is set on each target in Build Settings.

---

## Path B — Mac App Store

Different cert, different export plist, no notarization (App Store review replaces it).

### One-time setup

1. **3rd Party Mac Developer Application** cert (Xcode → Settings → Accounts → Manage Certificates → `+`)
2. **3rd Party Mac Developer Installer** cert (same place)
3. **App Store Connect listing** for each of the 4 bundle IDs (the app + 3 extensions each need their own listing record under the app's "Bundle ID" registration in Apple Developer portal, but only the parent app gets a public App Store page).
4. **Provisioning profiles** — Xcode handles via `-allowProvisioningUpdates` once the bundle IDs and certs exist.

### Local build script

Add a sibling `scripts/appstore-build.sh`:

```sh
#!/usr/bin/env bash
set -euo pipefail

SCHEME="DiskJockey"
CONFIG="Release"
BUILD_DIR="$(pwd)/build/appstore"
ARCHIVE="$BUILD_DIR/DiskJockey.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
TEAM_ID="43UMKXZ8P4"

mkdir -p "$BUILD_DIR"

xcodebuild -project DiskJockey.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -archivePath "$ARCHIVE" \
  -destination "generic/platform=macOS" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  archive

cat > "$BUILD_DIR/export-appstore.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/export-appstore.plist" \
  -allowProvisioningUpdates

# Upload via Transporter (GUI) or altool:
xcrun altool --upload-app -f "$EXPORT_DIR/DiskJockey.pkg" \
  --type macos \
  --apiKey "$APPLE_API_KEY_ID" \
  --apiIssuer "$APPLE_API_ISSUER"
```

After upload, finish in App Store Connect: screenshots, description, privacy nutrition labels, age rating, export compliance, submit for review.

### MAS-specific gotchas

- **Sandbox must be strict.** Your existing entitlements already use sandbox; just make sure no temporary exceptions sneak in (`com.apple.security.temporary-exception.*`).
- **No NSTask shell-outs to system binaries** that aren't sandbox-allowed. The `hdiutil` fallback in [DiskJockeyEXT4/EXT4FileSystem.swift](DiskJockeyEXT4/EXT4FileSystem.swift) needs verification — `hdiutil` is generally allowed but specific subcommands vary. Test in a sandboxed Release build before submitting.
- **FSKit + FileProvider** are first-class on macOS 15.4+; just set `LSMinimumSystemVersion` correctly. App Store accepts FSKit extensions.
- **No private API**. The static analyzer in App Store upload catches most of these.
- **Export compliance**: if the app uses no encryption beyond HTTPS / Apple-provided APIs, the standard exemption applies. Set `ITSAppUsesNonExemptEncryption = NO` in the main Info.plist to skip the per-build question.
- **Each extension's bundle ID** must be registered in the Apple Developer portal *as part of* the parent app's bundle ID (extensions are children). Xcode's automatic signing handles this once the parent is registered.

---

## Verifying any signed build

```sh
# After download (simulate quarantine to test Gatekeeper)
xattr -w com.apple.quarantine "0083;0;Safari;" /path/to/DiskJockey.app

spctl -a -vvv -t exec /path/to/DiskJockey.app
codesign --verify --deep --strict --verbose=4 /path/to/DiskJockey.app
stapler validate /path/to/DiskJockey.app   # Developer ID path only

# Inspect each embedded bundle
codesign -dvv /path/to/DiskJockey.app/Contents/PlugIns/DiskJockeyEXT4.appex
codesign -dvv /path/to/DiskJockey.app/Contents/PlugIns/DiskJockeyNTFS.appex
codesign -dvv /path/to/DiskJockey.app/Contents/PlugIns/DiskJockeyFileProvider.appex
```

`spctl` should report `source=Notarized Developer ID` (Path A) or simply `accepted` (Path B, after install from MAS).

---

## CI later (not yet)

DiskJockey has no `.github/workflows/release.yml` today. When you add one, the secret table is identical to the one in [diskcutter/docs/macos-pipeline.md](../../diskcutter/docs/macos-pipeline.md):

| Secret | Value |
|---|---|
| `APPLE_CERTIFICATE` | base64 of Developer ID `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | the `.p12` password |
| `APPLE_SIGNING_IDENTITY` | `Developer ID Application: Chris Thomas (43UMKXZ8P4)` |
| `APPLE_TEAM_ID` | `43UMKXZ8P4` |
| `APPLE_API_ISSUER` | Issuer UUID |
| `APPLE_API_KEY_ID` | 10-char Key ID |
| `APPLE_API_KEY` | base64 of `.p8` |
| `KEYCHAIN_PASSWORD` | random string for temp keychain |

CI build step won't use `tauri-action`; instead invoke `scripts/release-build.sh` directly after importing the cert into a temp keychain. Standard recipe — defer until needed.

---

## Safety

- Never log secrets. `base64 -d` output is NOT auto-masked by GitHub Actions.
- Restrict signing to tag pushes (never PR builds — forks could exfiltrate).
- Rotate the `.p12` cert and `.p8` key yearly. Revoke immediately if any collaborator account is compromised.
- API key (`.p8`) is scoped to App Store Connect actions only — strictly better than Apple-ID + app-password.
