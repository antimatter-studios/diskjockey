# NTFS extension: NDJSON sink permission denied

## Symptom

The `DiskJockeyNTFS` FSKit extension successfully mounts NTFS volumes
and emits `log.info` / `log.event` calls — but **nothing lands in
`ntfs.ndjson`** in the shared app-group container. `ext4.ndjson` for
the sibling `DiskJockeyEXT4` extension on the exact same path gets
written cleanly.

The NTFS extension's `os_log` output is captured (`log show --info
--debug --predicate "subsystem == 'com.antimatterstudios.diskjockey'
AND category == 'ntfs'"` shows every event). So our code runs; only
the file-sink path fails.

Downstream effect: the host app's `LogTailService` watches
`<group>/Logs/*.ndjson`. With `ntfs.ndjson` empty, the app never sees
the NTFS extension's structured events (`volume.dirty`, `fsck.start`,
`fsck.progress`, `fsck.done`), so the per-disk detail pane's dirty
badge + fsck progress bar stay blank even while the extension is
actively doing the work.

## Root cause (verified today)

After adding a diagnostic `Logger(subsystem: AppLog.subsystem,
category: "ndjson").error(...)` around the `FileHandle(forWritingTo:)`
init in `NDJSONFileSink`, the actual macOS error surfaced:

```
DiskJockeyNTFS[33290]: NDJSONFileSink open failed for ntfs at
  /Users/christhomas/Library/Group Containers/
  group.com.antimatterstudios.diskjockey/Logs/ntfs.ndjson:
  You don't have permission to save the file "ntfs.ndjson" in the
  folder "Logs".
```

The NTFS extension is being denied write access to the shared
app-group container. The EXT4 extension, with identical local
entitlements, opens it fine.

## What's actually different

Comparison of the two extensions' **signed local entitlements**
(`codesign -d --entitlements :- <appex>`):

| Key | EXT4 (works) | NTFS (fails) |
|---|---|---|
| `com.apple.application-identifier` | `…diskjockey.ext4` | `…diskjockey.ntfs` |
| `com.apple.developer.fskit.fsmodule` | true | true |
| `com.apple.developer.team-identifier` | 43UMKXZ8P4 | 43UMKXZ8P4 |
| `com.apple.security.app-sandbox` | true | true |
| `com.apple.security.application-groups` | `[group.com.antimatterstudios.diskjockey]` | `[group.com.antimatterstudios.diskjockey]` |

Local signed entitlements are **identical** other than the app ID.

But the **embedded provisioning profile inside each .appex** differs.
(`security cms -D -i <appex>/Contents/embedded.provisionprofile`):

EXT4 profile's `Entitlements` dict includes:
```
com.apple.application-identifier
com.apple.developer.fskit.fsmodule
com.apple.developer.team-identifier
com.apple.security.application-groups = [
  "group.com.antimatterstudios.diskjockey",
  "43UMKXZ8P4.*"
]
keychain-access-groups = [ "43UMKXZ8P4.*" ]
```

NTFS profile's `Entitlements` dict includes:
```
com.apple.application-identifier
com.apple.developer.fskit.fsmodule
com.apple.developer.team-identifier
(no application-groups)
```

The NTFS profile does **not grant** the `application-groups`
entitlement. The NTFS .xcent *claims* it. AMFI reconciles claim vs.
grant at runtime — the mismatch doesn't kill the process (we've
already confirmed probe + loadResource run fine and emit to os_log),
but it **silently strips access to the group container**, so any
file I/O into that container is denied.

EXT4's profile grants `application-groups` (the Apple Developer
portal has "App Groups" capability enabled on the `…diskjockey.ext4`
App ID and the group `group.com.antimatterstudios.diskjockey` is
associated with it). The NTFS App ID on the portal doesn't have that
capability enabled, so Xcode's automatic signing can't put it into
the NTFS profile.

## Fix

On developer.apple.com:

1. Identifiers → find `com.antimatterstudios.diskjockey.ntfs`
2. Enable the **App Groups** capability
3. In the App Groups modal, either:
   - Check the existing `group.com.antimatterstudios.diskjockey`
     (reusing the same group the main app and ext4 extension use
     — this is what we want so the three components share one
     container), OR
   - Configure a fresh group (only if intentionally isolating NTFS)
4. Save

Then on the local machine:

1. Xcode → Settings → Accounts → select team → **Download Manual
   Profiles** (forces a refresh; otherwise Xcode might keep serving
   the cached grant-less profile)
2. Product → Clean Build Folder
3. Rebuild DiskJockey

After rebuild, verify with:

```sh
security cms -D -i \
  ~/Library/Developer/Xcode/DerivedData/DiskJockey-*/Build/Products/\
Debug/DiskJockey.app/Contents/Extensions/DiskJockeyNTFS.appex/Contents/\
embedded.provisionprofile \
  | plutil -p - | grep -A1 application-groups
```

— the NTFS profile should now list `group.com.antimatterstudios.diskjockey`
and/or `43UMKXZ8P4.*` under `com.apple.security.application-groups`,
matching EXT4's.

## Verification after fix

- Mount an NTFS image; `ntfs.ndjson` in the shared container should
  grow with entries (probe called, loadResource called, volume.clean
  or volume.dirty, etc.).
- Running a known-dirty NTFS image: dirty detection should fire
  `volume.dirty` → `fsck.start` → `fsck.progress` × N → `fsck.done`
  events, all visible in `ntfs.ndjson`.
- Host app's `AttachedDiskDetailView` should light up the dirty badge
  + progress bar for that mount.

## Nothing to fix in code — portal-only

No code change is needed. All three layers (extension source, local
entitlements file, Makefile + build scripts) are already correct.
The fix lives entirely on the Apple Developer portal.

## Related: why EXT4 has App Groups on its App ID

Historical — when EXT4 was first wired up (earlier in the DiskJockey
project's life) the App Group was added to the ext4 App ID to enable
log-tailing into the host app. NTFS was added later and the same
portal-side capability add never happened.
