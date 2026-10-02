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

4. **libfs_ext4 vendored** under `vendor/fs_ext4/`. Refresh with:

   ```sh
   make vendor-fs-ext4 EXT4_SRC=vendor/rust-fs-ext4
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

File > Attach disk image… (⌘⇧E) ⇒ file picker. There is no name prompt
and no filesystem choice.

Under the hood, DiskJockey attaches the image with `hdiutil attach` (through
its agent) and mounts each resulting device with Disk Arbitration. DA probes
the device, picks the driver itself, and mounts the volume at
`/Volumes/<its own label>`; the app's log names the mount point DA reports.

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
# via UI: File > Detach volume… (⌘⇧U) — pick /Volumes/<name> in the
#         open panel, enter admin password if prompt appears.
# via CLI:
sudo /sbin/umount /Volumes/ext4-test
```

Test fixture images live under `vendor/rust-fs-ext4/test-disks/` — see
`docs/TEST-DISKS.md` in that repo for what each exercises.

## Known issues / gotchas

- **BUILD FAILED at code-sign step**: provisioning profile lacks
  `com.apple.developer.fskit.fsmodule`. See "Prerequisites" #3.
- **`mount: No such file or directory`** with no log output: extension
  didn't launch. Check Developer Mode + pluginkit registration.
- **Silent mount failure**: `mount -F` returns 0 but `/Volumes/<name>`
  is empty. Usually means `probe` refused the image (not ext4, or
  superblock magic mismatch). Check log stream.
- **Multi-level extent write / sparse truncate**: not supported in
  fs-ext4 v0.1. Reads always work; large / fragmented writes may fail
  loudly. See `vendor/rust-fs-ext4/CHANGELOG.md`.
- **SwiftProtobuf CLI build error** unrelated to ext4; builds succeed
  from Xcode which resolves the package graph properly.

## The extension registry: what decides which extension `mount` gets

This section covers every FSKit extension the app ships (ext4, NTFS, XFS,
Btrfs, EROFS, SquashFS), not only ext4. It exists because getting a freshly
built extension to serve a mount on 2026-09-10/11 took most of an evening,
and every obstacle turned out to be registry state, not code (diskjockey#167).
Four stores are involved, and they do not agree with each other:

| store | what it holds | how you see it | how you change it |
|---|---|---|---|
| pluginkit (`pkd`) | registered bundle paths per bundle id, each with a UUID | `pluginkit -mAvvv -i <bid>` | `pluginkit -a <path>`, `pluginkit -r <path>` |
| FSKit enablement | whether the user allowed the module | **System Settings → General → Login Items & Extensions → File System Extensions** | that toggle, and nothing else |
| LaunchServices (`lsd`) | the fstype → bundle lookup `mount` uses | `pluginkit -mAvvv -i <bid>` shows the paths it can pick from | `lsregister -u <path>`, `lsregister -f <path>` |
| `fskitd` | the running FSKit daemon's view | `log stream` | `scripts/dev.sh reset-daemons` |

### Four facts, measured on 2026-09-10/11

**1. `pluginkit` does not report FSKit enablement.** Its `+` means enabled
at the pluginkit level. That is a different flag from the one `mount` checks:

```
$ pluginkit -m -v -A -p com.apple.fskit.fsmodule | grep ext4
+    com.antimatterstudios.diskjockey.ext4(1.4.0)  …
$ /sbin/mount -F -t ext4 image.img /mnt
Module com.antimatterstudios.diskjockey.ext4 is disabled!
```

`pluginkit -e use -i <bid>` does not change what `mount` sees. **The System
Settings toggle is the gate.** It is not one of several things to try.

**2. Re-registering a module resets its enablement.** The record gets a new
UUID, and enablement belongs to the old one. Any `pluginkit -a`, any
`lsregister -u`/`-f`, or any app launch that re-registers its extensions
sends you back to System Settings. While you are diagnosing, this looks like
progress when it is not: the error message changes each time you
re-register and re-toggle.

**3. LaunchServices collects stale bundle paths, and a dead one can win.**
At one point seven paths were registered for
`com.antimatterstudios.diskjockey.ext4`: two per-session scratch builds under
`/private/tmp/claude-501/…`, three DerivedData directories (one of them an
`ArchiveIntermediates` copy), the bare DerivedData `Build/Products/Debug`, and
a project-local `build/Debug`. Four of the seven no longer existed on disk.
When a dead path wins the lookup, `mount` reports
`Probing resource: … No such file or directory`. That reads like a problem
with the image, but the problem is the registry.

**4. Deleting a registered bundle poisons the lookup, and killing `pkd`
empties the settings pane.** After `pkd` is killed, the module disappears
from the File System Extensions list, and you cannot re-enable it until `pkd`
is running again and the pane has been reopened. Check `pgrep -x pkd` before
you go looking for the toggle.

### The error messages are not a diagnostic ladder

Over that evening, `mount` alternated between `Unable to invoke task`,
`Module … is disabled!`, `Probing resource: ENOENT` and
`Probing resource: extensionKit error 2`. Registry state that looked the same
gave different messages. Do not read a change of message as having passed a
gate. Read the registry itself.

### Reading the registry

Every path registered for one bundle id is listed by `pluginkit -mAvvv -i`.
Run on 2026-09-30 against an `/Applications` install:

```
$ pluginkit -mAvvv -i com.antimatterstudios.diskjockey.ext4
+    com.antimatterstudios.diskjockey.ext4(1.3.0)
	            Path = /Applications/DiskJockey.app/Contents/Extensions/DiskJockeyEXT4.appex
	            UUID = 036F9228-9B3C-4E61-88E8-B6134C05F598
	   Parent Bundle = /Applications/DiskJockey.app
	     Parent Name = DiskJockey
 (1 plug-in)
$ pluginkit -mAvvv -i com.antimatterstudios.diskjockey.xfs
  (no matches)
```

One `Path =` line per registered copy. More than one line for a bundle id is
the condition fact 3 describes. `(no matches)` means that module is not
registered at all: the 1.3.0 install above predates the XFS and Btrfs
extensions.

`scripts/dev.sh registry` prints every registered path for every bundle id
the app ships. It marks each path `live` or `dead` depending on whether it
exists on disk, and `keep` for the one inside the bundle you mean to use. It
changes nothing unless you pass `--clear`:

```sh
scripts/dev.sh registry                      # list; changes nothing
scripts/dev.sh registry --clear              # deregister every path but the kept bundle's
scripts/dev.sh registry --clear --keep /Applications/DiskJockey.app
```

`--keep` defaults to the DerivedData app bundle `dev.sh build` produces. For
each stray, `--clear` runs `pluginkit -r <path>` and then `lsregister -u` on
the `.app` the path sits in. Both are edits to the registry, and after them
the kept bundle's module needs toggling again (fact 2).

### The order of operations that works

1. **Clear the strays.** Run `scripts/dev.sh registry`, read it, then
   `scripts/dev.sh registry --clear --keep <the app you will run>`. Do not
   delete a registered bundle directory before you deregister it (fact 4).
2. **Register one bundle.** Launch that app once. It registers its own
   extensions. Confirm with `scripts/dev.sh registry` that each bundle id
   shows exactly one path, and that it is marked `keep`.
3. **Make sure `pkd` is alive** (`pgrep -x pkd`), then enable each module in
   System Settings → General → Login Items & Extensions → File System
   Extensions.
4. **Do not re-register.** From here on, `pluginkit -a`, `lsregister -f`,
   `dev.sh pluginkit-reload`, `dev.sh doctor` and a relaunch from a
   different path all reset step 3. `dev.sh build` writes into the kept
   DerivedData bundle for exactly this reason.
5. If `mount` still fails, run `scripts/dev.sh reset-daemons` (it bounces
   `pkd`, `fskit_agent`, the per-user `lsd` and `fskitd`), reopen the
   settings pane, and check the toggle again before you look anywhere else.
   A change to an extension's `FSMediaTypes` in particular leaves `fskitd`
   holding the old table until that reset.

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

Initial read of this was "W2 is resolved" — that is **wrong**. The
embedded provisioning profile carrying `fskit.fsmodule` only proves
that Xcode's `.entitlements` file asks for the capability and
automatic signing generated a profile claiming it. The **portal's
bundle-id capability list for `com.antimatterstudios.diskjockey.ext4`
is empty** (see the follow-up evidence below). At runtime the kernel
+ `taskgated-helper` validates the claimed entitlement against the
portal's granted-capabilities list, not against the local
profile; if the portal hasn't granted the capability, the extension
process is killed at launch regardless of what the signed-in profile
says.

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
IMG=vendor/rust-fs-ext4/test-disks/ext4-basic.img
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

## W1 empirical probe — follow-up 2026-04-18 (post Developer Mode on)

Developer Mode enabled by the user. Extension now registers with
`pluginkit` once we use the trailing-slash path:

```
$ pluginkit -a /path/to/DiskJockeyEXT4.appex/
$ pluginkit -e use -i com.antimatterstudios.diskjockey.ext4
$ pluginkit -m -p com.apple.fskit.fsmodule | grep diskjockey.ext4
+    com.antimatterstudios.diskjockey.ext4(0.1.0)
```

First `mount -F` attempt:

```
$ osascript -e 'do shell script "/sbin/mount -F -t ext4 …img /tmp/dj-ext4-test" with administrator privileges'
0:154: execution error: mount: Unable to invoke task (69)
```

`mount` exit 69 = `EAUTH` (authentication error) — produced by
`fskitd` when it can't spawn the extension process. `log show`
during the attempt:

```
fskit_agent: Launching process bundleID: com.antimatterstudios.diskjockey.ext4
fskit_agent: Failed to create extensionProcess for extension
    'com.antimatterstudios.diskjockey.ext4'
    error: com.apple.extensionKit.errorDomain Code=2
    NSUnderlyingError: NSCocoaErrorDomain Code=4099
    "The connection to service with pid <X> was invalidated."
```

The extension host process started and was immediately killed. **No
crash report** is produced — AMFI kills it before it can run user
code. The Xcode ledger captured on the same timeline revealed the
actual reason:

```json
"identifier": "com.antimatterstudios.diskjockey.ext4",
"bundleIdCapabilities": { "meta": { "paging": { "total": 0 } } }
```

The Apple Developer portal has **zero** capabilities registered for
the `diskjockey.ext4` App ID. Xcode automatic signing generated a
profile claiming `com.apple.developer.fskit.fsmodule` anyway, because
the target's `.entitlements` file requests it; but at runtime
`taskgated-helper` validates the claimed entitlement against the
portal's granted-capabilities list, finds the mismatch, and kills the
extension before it can exec.

**Next user action (cannot be done from an agent session):**

1. developer.apple.com/account → Certificates, Identifiers & Profiles
   → Identifiers.
2. Find `com.antimatterstudios.diskjockey.ext4`.
3. Enable the **FSKit Module** capability. Save.
4. In Xcode, automatic signing will refresh the profile on the next
   build (or force it: Settings → Accounts → team → Download Manual
   Profiles).
5. Rebuild the app:
   ```sh
   xcodebuild -project DiskJockey.xcodeproj -scheme DiskJockey \
              -configuration Debug -destination "platform=macOS" build
   ```
6. Relaunch `DiskJockey.app`; `pluginkit -a <new-appex-path>/` again
   if the DerivedData path changed.
7. Re-attempt the `/tmp/dj-ext4-test` mount from the previous section.

Once the extension can actually launch, we get to S6–S9 and learn U1
(loopback vs hdiutil) empirically for real.

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
