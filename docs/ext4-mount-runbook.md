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
