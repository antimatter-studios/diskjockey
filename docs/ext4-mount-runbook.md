# ext4 mount runbook — DiskJockey + DiskJockeyEXT4 FSKit extension

End-to-end checklist for mounting an ext4 image via the DiskJockeyEXT4
extension on macOS 26. Assumes the Swift side has built cleanly in Xcode
(`DiskJockeyEXT4` target succeeds).

## Prerequisites

1. **macOS 26** (FSKit V2 API, `mount -F` flag).
2. **Developer Mode** enabled:

   ```sh
   sudo DevToolsSecurity -enable
   DevToolsSecurity -status   # expect: enabled
   ```

3. **Apple Developer account with FSKit Module capability** on the team.
   Without it, code signing fails at build time with:

   > Provisioning profile ... doesn't include the FSKit Module capability.

   Enable it in the App IDs config for
   `com.antimatterstudios.diskjockey.ext4`, then re-download the
   provisioning profile from Xcode > Settings > Accounts.

4. **libext4rs vendored** under `vendor/ext4rs/`. Refresh with:

   ```sh
   make vendor-ext4rs EXT4RS_SRC=/Volumes/sdcard256gb/projects/ext4-rust
   ```

## First launch

1. Open `DiskJockey.xcodeproj` in Xcode.
2. Select the **DiskJockey** scheme (not DiskJockeyEXT4).
3. ⌘R to Run. The main app launches and the embedded `.appex`
   automatically registers with pluginkit on first run.
4. Verify registration:

   ```sh
   pluginkit -m -v -p com.apple.fskit.fsmodule | grep diskjockey
   ```

   Expected output includes `+com.antimatterstudios.diskjockey.ext4`.

5. **Leave the DiskJockey app running.** FSKit extensions seem to require
   the host process to be live (based on the ext4-fskit test saga).

## Mount flow via the UI

File > Attach ext4 image… (⌘⇧E) ⇒ file picker ⇒ name prompt.

Under the hood, DiskJockey runs:

```sh
/sbin/mount -F -t ext4 <image-path> /Volumes/<name>
```

## Mount flow via CLI (for debugging)

Open **three terminal tabs**:

```sh
# 1. Log stream — extension subsystem
log stream --predicate 'subsystem == "com.antimatterstudios.diskjockey"' --info

# 2. Do the mount
sudo mkdir -p /Volumes/ext4-test
sudo /sbin/mount -F -t ext4 ~/path/to/ext4-basic.img /Volumes/ext4-test

# 3. Verify contents
ls -la /Volumes/ext4-test
stat /Volumes/ext4-test
```

Expected log sequence in (1):

- `probe: entered`
- `load: mounting ext4 volume`
- `load: mounted <volume-name>`

## Unmount

```sh
# via UI: repeat attach flow with "Unmount" intent (TBD)
# via CLI:
sudo /sbin/umount /Volumes/ext4-test
```

## Test matrix

Use the ext4 fixture images from `ext4-rust/test-disks/`:

| Image | Exercises |
|---|---|
| `ext4-basic.img` | minimal extent + dir entries |
| `ext4-htree.img` | hashed directory |
| `ext4-inline.img` | inline_data feature |
| `ext4-xattr.img` | xattr reads |
| `ext4-deep-extents.img` | multi-extent files |
| `ext4-csum-seed.img` | metadata_csum with csum_seed |

For each: mount read-only via `/sbin/mount -F -t ext4`, verify `ls` /
`cat` of the expected files, then `umount`. All test images are
self-documenting in `<image>.meta.txt`.

## Known issues / gotchas

- **BUILD FAILED at code-sign step**: provisioning profile lacks
  `com.apple.developer.fskit.fsmodule`. See "Prerequisites" #3.
- **`mount: No such file or directory`** with no log output: extension
  didn't launch. Check Developer Mode + pluginkit registration.
- **Silent mount failure**: `mount -F` returns 0 but `/Volumes/<name>`
  is empty. Usually means `probe` refused the image (not ext4, or
  superblock magic mismatch). Check log stream.
- **Multi-level extent write / sparse truncate**: not supported in
  ext4rs v0.1. Reads always work; large / fragmented writes may fail
  loudly. See ext4-rust/CHANGELOG.md.
- **SwiftProtobuf CLI build error** unrelated to ext4; builds succeed
  from Xcode which resolves the package graph properly.

## W1 empirical probe — findings 2026-04-18

Run by instance 1 against commit `b0307e5` on branch `new-ui`.

**Environment at probe time:**

```
$ sw_vers | head -2
ProductName:  macOS
ProductVersion: 26.x

$ DevToolsSecurity -status
Developer mode is currently disabled.             ← BLOCKER

$ ls ~/Library/Developer/Xcode/DerivedData/DiskJockey-*/Build/Products/Debug/DiskJockey.app/Contents/Extensions/
DiskJockeyEXT4.appex                              ← .appex embedded
```

**Signing + entitlement chain (all green):**

```
$ codesign -dv --entitlements :- DiskJockeyEXT4.appex
Identifier=com.antimatterstudios.diskjockey.ext4
TeamIdentifier=43UMKXZ8P4
CodeDirectory flags=0x10000(runtime)
Entitlements include:
  com.apple.developer.fskit.fsmodule=true         ← entitlement in sig
  com.apple.developer.team-identifier=43UMKXZ8P4
  com.apple.security.get-task-allow=true

$ security cms -D -i .../embedded.provisionprofile | grep fskit
  com.apple.developer.fskit.fsmodule=true         ← capability in profile
```

So the P8 plan's W2 (capability on portal) is **already resolved** — the
developer portal has the FSKit Module capability attached to App ID
`com.antimatterstudios.diskjockey.ext4`, and the embedded profile
carries it into the signed `.appex`.

**pluginkit still refuses to register the appex:**

```
$ open DiskJockey.app     # launches OK, pid visible
$ pluginkit -m -v -p com.apple.fskit.fsmodule | grep diskjockey
(no output)

$ pluginkit -a <path-to-.appex>
(exits silently, non-zero — plugin still absent from -m listing)
```

Interpretation: Developer Mode must be **enabled** on the host before
pluginkit accepts dev-signed FSKit extensions (empirical confirmation
of S3 in the P8 plan). Until then S4-S9 can't even start — `mount -F`
returns "Operation not permitted" with no extension logs because
fskitd has nothing to dispatch to.

**User action required to unblock W1:**

```sh
sudo DevToolsSecurity -enable
DevToolsSecurity -status    # must return: Developer mode is currently enabled.
```

Needs admin password, can't be done non-interactively from an agent
session.

**Once Developer Mode is on, re-run W1:**

```sh
# 1. Verify plugin is now registered
open ~/Library/Developer/Xcode/DerivedData/DiskJockey-*/Build/Products/Debug/DiskJockey.app
pluginkit -m -v -p com.apple.fskit.fsmodule | grep diskjockey.ext4
#   expect: +com.antimatterstudios.diskjockey.ext4(0.1.0)

# 2. /tmp stepping-stone mount (user's debug path)
MP=/tmp/dj-ext4-test
IMG=/Volumes/sdcard256gb/projects/ext4-rust/test-disks/ext4-basic.img
mkdir -p "$MP"
log stream --predicate 'subsystem == "com.antimatterstudios.diskjockey.ext4"' --info &
sudo /sbin/mount -F -t ext4 "$IMG" "$MP"

# 3. Verify
ls "$MP"                    # expect: contents per ext4-basic.meta.txt
sudo /sbin/umount "$MP"

# 4. If step 2 fails with a fskitd "cannot get block device" error, then
#    macOS 26's mount -F does NOT loopback-attach .img transparently.
#    Fallback path:
DEV=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" | awk '{print $1; exit}')
sudo /sbin/mount -F -t ext4 "$DEV" "$MP"
ls "$MP"
sudo /sbin/umount "$MP"; hdiutil detach "$DEV"
```

Until those commands run, U1 (loopback vs hdiutil) and U2 (/tmp mount
acceptance) remain open. FSKitMountService already passes an image path
straight to `mount -F` — if U1 reveals hdiutil-first is required, that
wiring gets wrapped in a source-resolver (P8 plan W5).

## Write path — cautions

Writing through FSKit ext4 mounts is possible in v0.1 but rough:

- First-level extent tree growth only (fails loudly past one extent
  root of fragmentation).
- No sparse file extension via truncate-to-larger-size.
- No `setxattr`, `chmod`, `chown`, `utimens` — missing from the C ABI.
- Journal replay on mount is done; **in-flight transaction wrapping
  of write ops is not**. Do NOT write to valuable data until the
  journaled write path lands.

Prefer read-only mounts for production use. For scratch images, write
is safe.
