# P8 — End-to-end ext4 mount plan

**Goal (user, verbatim):** Run DiskJockey. Pick one of the `test-disks/`
ext4 images. See the volume mount under `/Volumes/`. That is success.

Secondary goal: if `/Volumes/` fights us (permissions, caching, stale
mounts), `/tmp/<name>` is an explicit stepping-stone mount point while
we debug.

Current state (commits on `new-ui`):

- `1159d8b` DiskJockeyEXT4 target registered in xcodeproj.
- `8055cd7` Swift sources wired against the vendored ext4rs C ABI.
- `917d5df` runbook in `docs/ext4-mount-runbook.md`.
- `0022bfb` File menu → "Attach ext4 image…" + `FSKitMountService`.
- `0a58253` Swift-6-clean `OSAllocatedUnfairLock` migration.
- `b0307e5` `/sbin/mount` routed through `osascript` admin auth.

xcodebuild succeeds with `CODE_SIGNING_ALLOWED=NO`. No real mount has
been attempted yet.

## 1. Problem decomposition — the stages between "compiles" and "mounted"

Every single one of these must succeed, in order, for a mount to land:

| Stage | What must happen | Fails silently? |
|---|---|---|
| S1 | `.appex` **code-signs** with a profile that includes `com.apple.developer.fskit.fsmodule` | No — Xcode signing error |
| S2 | DiskJockey.app **runs at least once**; macOS registers the embedded `.appex` via pluginkit | Partially — pluginkit list tells you |
| S3 | Developer Mode is **enabled** on the host (`DevToolsSecurity -enable`) | Yes — extension silently refuses to launch |
| S4 | `mount -F -t ext4 <src> <mp>` finds the FSModule whose `FSShortName=ext4` is pluginkit-registered | Yes — exits 1 with empty log |
| S5 | fskitd **spawns the extension process** (the `.appex` binary) | Yes — AMFI kills it silently if entitlements/signing diverge |
| S6 | fskitd produces an `FSBlockDeviceResource` for the source path (image file OR `/dev/diskN`) | Unknown on macOS 26 for raw `.img` |
| S7 | `EXT4FileSystem.probeResource` returns `.usable` (checks ext4 magic `0xEF53` at offset 1024) | Yes — returns `.notRecognized` on any read error |
| S8 | `EXT4FileSystem.loadResource` calls `ext4rs_mount_with_callbacks` — succeeds, FSVolume activates | Yes — error lives in `ext4rs_last_error`, must be logged |
| S9 | FSKit / VFS attaches the returned volume at the mountpoint; `/Volumes/<name>` becomes a real mount | Sometimes — Finder cache lag |

Silence at any stage looks identical to "still waiting." This is the
reason the runbook has a `log stream` step sitting in a second
terminal for the whole mount attempt — we need to see which stage
actually fires.

## 2. Known unknowns

These are the empirical questions nobody has answered yet, and they
gate the work below:

- **U1 — Loopback.** Does macOS 26 `mount -F -t ext4 /path/to/image.img /mnt`
  loopback-attach the file automatically (producing the block resource
  for S6), or must we `hdiutil attach -nomount` first and pass
  `/dev/diskN`? The ext4-fskit repo's mount saga used hdiutil
  explicitly; fskit V2 semantics on macOS 26 may differ.
- **U2 — /tmp acceptance.** Does `/sbin/mount -F` accept a non-`/Volumes`
  mountpoint? Per the user hint we expect yes, but it needs a one-shot
  test. If it works, it's our fast debug path (skips DiskArbitration
  cache, runs without admin on a writable `/tmp/*`).
- **U3 — Capability gate.** Is the `com.apple.developer.fskit.fsmodule`
  capability currently attached to App ID
  `com.antimatterstudios.diskjockey.ext4` on the Apple Developer
  portal? Without it, `.appex` can build (via `CODE_SIGNING_ALLOWED=NO`)
  but will not launch under AMFI → S5 fails silently.
- **U4 — Subsystem alignment.** All DiskJockeyEXT4 loggers now use
  `com.antimatterstudios.diskjockey.ext4`. We have not confirmed the
  `log stream --predicate "subsystem == \"com.antimatterstudios.diskjockey.ext4\""`
  invocation actually emits lines when the extension is alive. Needs a
  probe-only test.

## 3. Work items

Each item has: **scope** (code/docs touched), **owner** (suggested,
based on claim patterns), **depends**, **acceptance** (the exact
check that proves it's done).

### W1 — Empirical answer for U1 + U2 (fastest unblocker)

**Scope:** Two shell invocations + a short notes update.
**Owner:** anyone — one-shot, 5 min.
**Depends:** DiskJockey launched once + pluginkit shows `+`. Takes
U3 as an input; if signing blocks S5, this item turns into "validate
failure mode is legible in log stream."
**Acceptance:** Commit notes in `docs/ext4-mount-runbook.md`:
- Exact command that mounted a test-disks image (or the exact error).
- Exact result for `/tmp/<name>` mountpoint (success vs `mount: …`).
- If hdiutil-first was required, the wrapped-command sequence.

Procedure:

```sh
# 1. bare attempt — per user hint, try /tmp first; easier cleanup
MP=/tmp/dj-ext4-test
IMG=/Volumes/sdcard256gb/projects/ext4-rust/test-disks/ext4-basic.img
mkdir -p "$MP"
sudo /sbin/mount -F -t ext4 "$IMG" "$MP"
ls "$MP"
sudo /sbin/umount "$MP"

# 2. if step 1 failed with EACCES/EINVAL, try hdiutil-first
DEV=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" | awk '{print $1; exit}')
sudo /sbin/mount -F -t ext4 "$DEV" "$MP"
ls "$MP"
sudo /sbin/umount "$MP"
hdiutil detach "$DEV"
```

### W2 — Signing & entitlement resolution (likely user-driven)

**Scope:** Apple Developer portal config **or** a documented Xcode
manual-profile workflow. No code if the portal path works.
**Owner:** user (portal login) + @5 or @1 (manual-profile fallback).
**Depends:** User decision between path (A) — enable capability in
portal, let Xcode refresh profile; and (B) — local dev-signed builds
only, accept no real mount until ship time.
**Acceptance:**
- Path A: `xcodebuild -scheme DiskJockey build` succeeds **without**
  `CODE_SIGNING_ALLOWED=NO`, and the built `.appex`'s embedded
  provisioning profile (`security cms -D -i <path to embedded.provisionprofile>`)
  lists `com.apple.developer.fskit.fsmodule`.
- Path B: runbook amended to explicitly state this build path cannot
  pass S5; only `CODE_SIGNING_ALLOWED=NO` local dev flow is viable,
  and actual mount testing deferred.

### W3 — pluginkit confirmation

**Scope:** No code. Runbook + a one-line add to the attach flow that
surfaces "not registered" clearly.
**Owner:** anyone.
**Depends:** W2 (to produce a signable appex) or W2-Path-B disclaimer.
**Acceptance:**
- `pluginkit -m -v -p com.apple.fskit.fsmodule | grep diskjockey.ext4`
  returns a `+`-prefixed line after first `open DiskJockey.app`.
- `FSKitAttachController.promptAndAttach` detects the missing-`+`
  state and surfaces a clear NSAlert instead of attempting `mount -F`
  and returning a cryptic EPERM. Useful when a user has forgotten to
  launch the app first.

### W4 — Log-stream visibility probe

**Scope:** No code (runbook step) OR 5-line helper that emits a one-
shot `logger.info` from `EXT4FileSystem.probeResource` and checks it
lands. Mostly runbook.
**Owner:** anyone.
**Depends:** S5 reachable (W2 + W3).
**Acceptance:** Running

```sh
log stream --predicate 'subsystem == "com.antimatterstudios.diskjockey.ext4"' \
           --info --debug
```

in a second terminal during a mount attempt produces at least the
`probeResource called` line. Documented in runbook with the exact
first-line.

### W5 — FSKitMountService fallback strategy

**Scope:** `DiskJockeyApplication/Services/FSKitMountService.swift`.
**Owner:** instance 1 (already in that file).
**Depends:** W1 (so we know which of direct-mount vs hdiutil-first is
correct).
**Acceptance:**
- If U1 = direct works → no code change; keep current `attach`.
- If U1 = hdiutil required → add a `sourceResolver(_ path: String) ->
  String` that runs `hdiutil attach -nomount` for regular files and
  returns `/dev/diskN`, passes through for `/dev/*`. Add a matching
  detach side that releases the hdiutil device.
- Either way, add an optional `mountPoint` param so the
  menu/debug flow can target `/tmp/<name>`.
- Build green: `xcodebuild -scheme DiskJockey ... build` still exits 0.

### W6 — Debug-mount UI (optional stepping stone)

**Scope:** `DiskJockeyApplication/DiskJockeyApp.swift` (add a second
menu item or option) + `FSKitAttachController`.
**Owner:** instance 1 or whoever has UI cycles.
**Depends:** W5.
**Acceptance:** A "Attach to /tmp (debug)…" menu item that takes the
image path and a name, mounts at `/tmp/<name>` instead of
`/Volumes/<name>`. Handy when `/Volumes` is cluttered or DiskArbitration
is caching stale entries during iteration.

### W7 — Final smoke: write the verification log

**Scope:** `docs/ext4-mount-runbook.md` → expand to include actual
captured output from a real run (not hypothetical).
**Owner:** whoever lands W1 + W2.
**Depends:** W1 + W2 + W3 + W4 green.
**Acceptance:**
- Runbook has a new section "Verified run 2026-04-18" with the exact
  log-stream snippet (probe → load → mounted), exact `ls /Volumes/<name>`
  output vs the image's `.meta.txt` baseline, and exact umount-clean
  evidence.
- After all of that, the project README / repo-level status can
  honestly say "ext4 mounts work end-to-end on macOS 26 via
  DiskJockey."

## 4. Critical path

```
W1 (empirical) ─┐
                ├─▶ W5 (wrap attach if hdiutil needed) ─┐
W2 (signing) ───┼─▶ W3 (pluginkit)                      ├─▶ W7 (verified run)
                └─▶ W4 (log visibility)                 ─┘
```

W2 is the hardest blocker: it needs user action (Apple Developer portal)
and nothing here can work-around it for a real mount. W1 can be done
**now** with `CODE_SIGNING_ALLOWED=NO` dev builds, and tells us whether
W5 is needed. W6 is a nice-to-have; everything else is load-bearing.

## 5. Risks + mitigations

- **AMFI silent kill.** If S5 fails because of a mismatched entitlement,
  `log stream` won't show our subsystem at all. Mitigation: run the
  probe-specific command

  ```sh
  log stream --predicate 'processImagePath contains "DiskJockeyEXT4"' --info
  ```

  which catches the extension-launch lifecycle from outside our
  subsystem.
- **Multi-level extent writes are known broken** in ext4rs v0.1 — but
  our goal is read-only mount visibility, not writes. Read path should
  be fine.
- **DiskArbitration caching.** If a prior failed mount left a stale
  entry in `/Volumes`, new mounts with the same name fail. Mitigation:
  W6 uses `/tmp/<name>` which DiskArbitration ignores; also
  `diskutil unmountDisk force /Volumes/foo` clears a stuck mount.
- **"Works on my machine" drift.** Once we have a verified run, record
  `sw_vers`, `xcode-select -p`, and `ls -la
  vendor/ext4rs/ext4rs.xcframework/` in the runbook. Makes
  regression-hunting tractable later.

## 6. Outcome

End of W7 and we're at the user's goal: DiskJockey.app → menu →
test-disks/ext4-basic.img → mount appears at `/Volumes/ext4-basic`
(or `/tmp/ext4-basic` debug) → `ls` returns the fixture contents
(`hello.txt`, subdirs, etc) → umount clean. That is P8.

P9 (archive `ext4-fskit` repo) becomes a routine follow-up.
