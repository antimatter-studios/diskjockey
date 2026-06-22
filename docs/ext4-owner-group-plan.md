# EXT4 owner / group manipulation — design plan

Status: **proposal — not yet implemented**
Authored: 2026-06-02 / Chris + Claude

## What you can do today

`fs_ext4_chmod` and `fs_ext4_chown` are both exposed by the Rust
driver, plumbed through `EXT4Backend`, and wired into
`EXT4Volume.setAttributes`. The driver takes **numeric uid/gid only**
(`UInt32?`) — no string resolution, no `/etc/passwd` lookup, no
assumption about whose user database is authoritative. So:

```sh
sudo chown 1000:1000 /Volumes/rootfs/home/pi
```

…goes straight through to the inode. **The driver is not the problem.**

## What feels broken — three separate things

1. **macOS POSIX gates chown above us.** The kernel rejects "chown a
   file to someone who isn't you" with EPERM before it reaches our
   `setAttributes`, unless the caller is root. That's why `sudo`
   works and bare `chown` doesn't. Not a DiskJockey-side issue.

2. **No UI surface in Finder.** Finder's *Get Info* only knows local
   macOS users (501, 502, …). It can't pick "1000" because there's
   no local user with that uid. So even though the capability is
   wired, the only way to exercise it today is Terminal + sudo.

3. **`createItem` inherits the calling macOS user.** This one is
   surprising and *is* a DiskJockey-side question. When Finder (or
   anything else going through our FSKit extension) creates a new
   file or directory, the new inode currently picks up the calling
   user's uid/gid because we don't override them.

   Concrete evidence: a freshly-imaged Raspberry Pi SD card mounted
   on this Mac:

   ```
   /Volumes/rootfs/home/pi  →  christhomas:staff (501:20)
   ```

   On the Pi itself that directory is `pi:pi (1000:1000)`. Our
   driver isn't overlaying anything in `stat` — `attr.uid` /
   `attr.gid` come straight from the on-disk inode. So the 501:20
   really is what's stored, written by some prior FSKit-side
   create (a Finder drop, a `.DS_Store`, anything). The original
   `useradd`-time 1000:1000 survives only on inodes nothing has
   touched since the Pi last wrote to them.

## What I'm proposing — Option A + B

### A — Read the volume's own user database at mount

On every mount the extension reads `/etc/passwd` and `/etc/group`
**from the mounted ext4 volume itself** (well-known absolute paths
on the volume). Parse them and surface a `volume.users` event the
host app's `AttachedDisksModel` ingests, alongside the existing
`volume.info` event.

The host app caches the mapping per-mount. UI can render
**"pi (1000)"** instead of **"1000"**, using the volume's own
authoritative names. Works perfectly for:

* Raspberry Pi rootfs cards
* Server / NAS disk-image backups
* Container root filesystem images
* Any general-purpose ext4 partition that has `/etc/passwd`

Falls back gracefully:

* Volume with no `/etc/passwd` (freshly-formatted, swap partition,
  bare data volume) → UI shows numeric uid/gid as today.
* Volume mounted in a sub-path that doesn't include `/etc/`
  (partition slice that's just `/usr`) → same fallback.

**Why this is the right starting point:** the volume's own passwd
file is the only naming source that's actually correct for a
foreign filesystem. The macOS DirectoryService can't help — uid
1000 on this Mac is some random local user (or no user at all), not
`pi`. We use the names the *volume* knows about, not the names the
*host* knows about.

### B — User-provided override / fallback mapping

A per-mount config file the user edits by hand. Format intentionally
boring — one line per mapping:

```
# ~/.diskjockey/mount-overrides/<volume-uuid>/uid-map
0=root
1000=pi
1001=alice
33=www-data
```

```
# .../gid-map
0=root
1000=pi
33=www-data
```

When the host app builds the chown UI's name picker, it overlays
this on top of whatever A produced. Useful for three cases:

* **Volume has no `/etc/passwd`** (the A fallback case above).
* **Display names should differ from the volume's own** (e.g. you
  want "Production Backup User" instead of "user1001").
* **You're chown'ing to a uid that doesn't exist in the volume's
  passwd** but you know is correct on the system this volume will
  eventually mount on.

A reads `/etc/passwd` once at mount; B is consulted lazily by the
host-app UI when rendering pickers. They compose.

## What this does *not* solve on its own

* **The kernel still requires root for `chown bob file`** when bob
  isn't you. Our UI flow could either (i) explain that in the
  chown dialog and tell the user how to elevate, or (ii) submit
  chown requests via a privileged helper (the DiskJockeyAgent
  pattern from `install-agent-dev.sh` — once the Agent is an
  actual Xcode target). Option (ii) is the right end state; (i)
  is fine for v1.

* **Finder's *Get Info* will still only know local macOS users.**
  We can't fix that — it's Finder's own UI. The DiskJockey-side
  chown UI is what unlocks numeric/foreign chown in practice.

## Open design questions

These need answers *before* we cut code:

### Q1 — what should `createItem` use for uid/gid on new inodes?

Today: inherits the calling macOS user (resulting in the 501:20
situation above). Three options:

* **(a) Status quo.** Keep inheriting the macOS caller. Easy; sometimes
  surprising on Linux-flavoured volumes.
* **(b) Per-mount configurable default.** Mount option like
  `default_uid=1000 default_gid=1000`. The user picks "pretend
  everything I create is owned by pi" once, in the mount setup UI.
  Honest about the trade-off, predictable.
* **(c) POSIX-ish inheritance.** New files take the parent
  directory's owner/group. Matches Linux behaviour when the
  setgid bit isn't involved. Slightly more code (a stat-of-parent
  before each create) but feels right.

My weak preference: **(b) for v1**, ship the option in the mount
config UI, default it to "macOS calling user" (today's behaviour)
so we don't regress; add (c) later as a per-mount toggle if the
manual config feels tedious.

### Q2 — where does the chown UI live?

* **(i) DiskJockey detail-pane UI.** Right-click a file in our own
  app, pick "Change owner…". Avoids Finder entirely. We render the
  name picker from the A+B mapping. Calls our `EXT4Backend.chown`
  directly. Bypasses the macOS-POSIX-only-root rule because the
  FSKit extension's `setAttributes` is the kernel-side path and it
  can write the inode regardless of caller privileges *if FSKit
  delegates the call to us*. **Needs verification:** does FSKit
  let chown through to our `setAttributes` when the caller isn't
  root? Or does it gate at the kernel level before we see it?

* **(ii) Terminal-only with documented incantation.** Lowest
  effort. No UI; just write `docs/ext4-chown.md` explaining
  `sudo chown 1000:1000 …`. Fine for power users, useless for
  everyone else.

* **(iii) Defer — focus on A+B's name rendering only, no chown UI
  at all in v1.** Just makes the existing numeric chown more
  understandable in any UI we have today (the detail view's
  "Owner" row). User still uses Terminal but at least sees
  meaningful labels everywhere.

**Don't know yet.** Q1's resolution feeds into Q2 — if create-time
ownership is configurable per-mount, that takes most of the
day-to-day pain off the chown path, and (iii) becomes more
attractive.

### Q3 — should we cache `/etc/passwd` across mounts of the same volume?

The volume's UUID is in the on-disk superblock. We could read
passwd once per UUID and cache the parsed result in
`<App Group>/users/<volume-uuid>.json`, refreshing on mount only
if `/etc/passwd`'s mtime changed.

Probably overkill — `/etc/passwd` is tiny (a few KB), and reading
it on every mount adds milliseconds. **Skip caching for v1.** Add
only if profiling shows it matters.

### Q4 — gid resolution: is `/etc/group` enough?

Same shape as passwd. `getent group` on Linux merges
`/etc/group` with NSS-configured sources (LDAP, AD, etc.). We
won't have those, but the local file is what's authoritative for
a Pi rootfs / single-machine server image. **Yes, just read
`/etc/group` and call it done.** Document the limitation.

## Affected files (sketch — for future implementation)

```
vendor/rust-fs-ext4/                   — no change (numeric API
                                          already correct)

DiskJockeyEXT4/EXT4Backend.swift       — no change (chmod/chown
                                          already wired)
DiskJockeyEXT4/EXT4FileSystem.swift    — in loadResource: after
                                          fs_ext4 mounts, read
                                          /etc/passwd + /etc/group
                                          via backend.readFile,
                                          parse, emit volume.users
                                          event
DiskJockeyEXT4/EXT4Volume.swift        — possibly: createItem
                                          override per Q1.b/c

DiskJockeyLibrary/                     — new file:
  VolumeUserDatabase.swift               passwd/group parser
                                          (vendor-agnostic — NTFS
                                          could reuse if it ever
                                          surfaces ACL UID mapping)

DiskJockeyApplication/Models/          — extend AttachedDisksModel:
  AttachedDisksModel.swift               consume volume.users events;
                                          expose user-name lookup
                                          to the UI layer
DiskJockeyApplication/Views/           — new view (Q2):
  …                                      chown picker / owner row
                                          rendering with name+uid

~/.diskjockey/mount-overrides/         — new directory (Option B);
  <uuid>/uid-map                         user-edited mapping files
  <uuid>/gid-map
```

## Decision needed before implementation

1. **Q1**: pick (a) / (b) / (c) for `createItem` default ownership.
2. **Q2**: pick (i) / (ii) / (iii) for the chown UI surface.
3. **Verify**: does FSKit delegate chown to our `setAttributes` when
   the caller isn't root? (Quick test from the running app: log
   in `setAttributes` whether chown bits arrive with EPERM-style
   filtering done upstream or whether we see the raw request.)

Once those three are settled, implementation is mechanical and
the doc above gets promoted from "plan" to "shipped 2026-XX-YY"
in the CHANGELOG.
