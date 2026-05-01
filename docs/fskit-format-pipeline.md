# FSKit format pipeline — current state, gaps, and wiring plan

How the in-app **Format as ext4** / **Format as NTFS** buttons in
`RawDiskDetailView` actually reach the Rust mkfs we shipped in
`vendor/rust-fs-{ext4,ntfs}`. The CLI binaries (`mkfs.ext4`,
`mkfs.ntfs`) are NOT used by the app — App Store sandbox rules forbid
bundling CLI tools, so the GUI path goes through FSKit's native
`startFormat` API.

This document captures **what FSKit gives us, what it doesn't, and the
honest current state** of the wiring. The trickiest bit isn't writing
the bytes — that's solved. It's "how does FSKit hand the extension a
device to format?" which the API does NOT make obvious.

## The end-to-end target pipeline

```
RawDiskDetailView (host app)
  └─ "Format as ext4" button
     └─ osascript -e 'do shell script "..." with administrator privileges'
        └─ /sbin/newfs_fskit -t ext4 /dev/diskN          (admin context)
           └─ fskitd routes the format request
              └─ DiskJockeyEXT4Module.startFormat(task:options:)
                 └─ fs_ext4::mkfs::format_filesystem(cfg, ...)
                    └─ writes superblock + BGD + bitmaps + root inode
```

Per-action admin prompt (osascript) is a deliberate safety choice — see
`memory/project_format_disks_plan.md`. Every format = fresh prompt =
mistaken double-click can't slip through.

## What FSKit's `startFormat(task:options:)` provides

From `FSResource.h` (macOS 26.2 SDK, `FSManageableResourceMaintenanceOperations`):

```objc
-(NSProgress * _Nullable)startFormatWithTask:(FSTask *)task
                                     options:(FSTaskOptions *)options
                                       error:(NSError**)error
```

**Crucially:** no `FSResource` parameter. The extension is told "format
something" but has to figure out *which device* on its own. Compare
with `loadResource(resource:options:replyHandler:)` (which DOES hand
us a resource).

`FSTaskOptions` exposes:
- `taskOptions: [String]` — argv-style, e.g. `["-t", "ext4", "/dev/disk5"]`
- `urlForOption(_ option: String) -> URL?` — for path-tagged options the
  module declares in `FSFormatOptionSyntax`

So the device path is in `taskOptions` somewhere, but the extension
must **open it itself** rather than receiving an already-opened
`FSBlockDeviceResource`. Inside the FSKit sandbox profile this needs
non-trivial entitlement plumbing to actually `open(2)` `/dev/disk*`.

## The two real options for the leaf

### Option A — `mountedResources` lookup (matches `startCheck`)

`EXT4FileSystem.startCheck` resolves the mount via the
`mountedResources` map keyed by `ObjectIdentifier(FSResource)`,
populated by `loadResource`. Same trick can apply to `startFormat`:
require the disk to be loaded (mounted) first, then format the loaded
device.

**Problem:** formatting a mounted volume is hostile — the kernel buffer
cache has dirty buffers for the existing FS, and overwriting the
on-disk metadata while it's mounted produces immediate read errors
and a corrupt unmount. macOS's `diskutil eraseDisk` works around this
by unmounting first, formatting, then re-mounting.

**For us:** safe usage requires the user to unmount before clicking
Format, OR for our extension to issue the unmount itself (needs
DiskArbitration, which the host-app side already has via
`DiskArbitrationService`).

### Option B — open `/dev/diskN` directly from `taskOptions`

Skip the FSKit resource abstraction. Read the device path out of
`taskOptions`, open it via `open("/dev/diskN", O_RDWR)`, wrap in
`FileDevice::open_rw`, call `fs_ext4_mkfs`.

**Problem:** the FSKit extension's sandbox profile may not permit
opening raw `/dev/disk*` paths. Investigation needed.

## Current state (this commit)

`startFormat` in both extensions is implemented as an **honest
placeholder**:
- Resolves the device via the `mountedResources` map (same pattern as
  fsck).
- If a resource is loaded, calls `fs_*_mkfs` against the existing
  `BlockDeviceContext` — **technically writes the new filesystem but
  is unsafe if the volume is currently mounted by macOS.** The Rust
  call succeeds; what happens in the kernel buffer cache afterwards
  is undefined.
- If no resource is loaded, throws `ENOTSUP` with a clear error
  message pointing at this doc.

The `RawDiskDetailView` Format buttons are wired to invoke
`/sbin/newfs_fskit -t <fstype> /dev/diskN` via osascript with admin
privileges. The full pipeline is plumbed from button click to extension
entry point. **What's not yet correct is the leaf** — actually
formatting safely.

## What's required before the leaf is production-ready

1. **Pre-flight unmount** — before `fs_*_mkfs` runs, the extension (or
   the host app, before invoking newfs_fskit) must unmount the volume.
   The host-app `DiskArbitrationService` already has the hooks for
   this. Cleanest: have the host app run `diskutil unmountDisk` (or
   call DA's `DADiskUnmount`) before the osascript prompt.
2. **Pre-format confirmation dialog** — destructive op; show the
   target disk, its label, and "ERASE EVERYTHING" copy before the
   admin prompt. Per-action prompt is the safety net but the user
   should also see what's about to be erased.
3. **Re-mount or re-probe after** — `fs_*_mkfs` produces a fresh
   filesystem; the system needs to re-probe to discover it. macOS
   typically does this automatically after `diskutil eraseDisk`, but
   our path may need an explicit `diskutil mount` after.
4. **Investigate Option B** — direct `/dev/diskN` open from inside
   the extension. If the sandbox profile permits it (with FSKit
   entitlement), this is cleaner because it doesn't require the
   chicken-and-egg "load the FS first" dance for blank disks.

## What works *today* with this wiring

- Pipeline is end-to-end plumbed: button → admin prompt → newfs_fskit
  → extension routing → Rust call.
- Format an *already-mounted* ext4 / NTFS volume IF you accept the
  caveat that the active mount becomes inconsistent and you should
  unmount immediately after.
- All error paths surface a clear message.

## What does NOT work yet

- Formatting a blank/raw disk (no recognized FS, never loaded).
- Safe in-place reformat of a live volume.
- macOS Disk Utility.app's "Erase as ext4 / NTFS" dropdown — that
  goes through a slightly different code path (`FSCheckTask` hooked
  via `FSManageableResource`), needs a separate session to investigate.

## Next session

Pick one of:
- **A**: extend the host app's pre-format flow to unmount the target
  via `DiskArbitrationService` *before* invoking `newfs_fskit`. Keeps
  the leaf as-is (operates on an unloaded resource → throws
  `ENOTSUP`), so we'd need to switch to opening `/dev/diskN` directly
  in the extension. Probably the right path long-term.
- **B**: prototype Option B (direct `/dev/diskN` open in the
  extension) on a test SD card to see if the FSKit sandbox lets us.
  If yes, the leaf gets simple and safe in one step.
