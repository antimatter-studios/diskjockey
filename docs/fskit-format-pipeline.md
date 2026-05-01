# FSKit format pipeline — current state and wiring

How the in-app **Format as ext4** / **Format as NTFS** buttons in
`RawDiskDetailView` actually reach the Rust mkfs we shipped in
`vendor/rust-fs-{ext4,ntfs}`. The CLI binaries (`mkfs.ext4`,
`mkfs.ntfs`) are NOT used by the app — App Store sandbox rules forbid
bundling CLI tools, so the GUI path goes through FSKit's native
`startFormat` API, driven by macOS's `diskutil`.

The first iteration of this pipeline used `/sbin/newfs_fskit -t ...`,
which had real limitations (couldn't format blank/raw disks, would
corrupt the kernel buffer cache if the volume was mounted). We've
since switched to `diskutil eraseDisk` / `eraseVolume`, which is a
strict superset and handles those edge cases natively. This doc
captures the new pipeline and what's left to do.

## The end-to-end pipeline

```
RawDiskDetailView (host app)
  └─ "Format as ext4" button → confirmation alert
     └─ osascript -e 'do shell script "..." with administrator privileges'
        ├─ Whole disk:  /usr/sbin/diskutil eraseDisk ext4 NAME GPT diskN
        └─ Single slice: /usr/sbin/diskutil eraseVolume ext4 NAME diskNsM
            (diskutil handles unmount → format → re-probe → re-mount)
              └─ macOS routes the format through FSKit
                 └─ DiskJockeyEXT4Module.startFormat(task:options:)
                    └─ fs_ext4::mkfs::format_filesystem(cfg, ...)
                       └─ writes superblock + BGD + bitmaps + root inode
```

Per-action admin prompt (osascript) is a deliberate safety choice — see
`memory/project_format_disks_plan.md`. Every format = fresh prompt =
mistaken double-click can't slip through.

## Why `diskutil eraseDisk` over `newfs_fskit`

- **Pre-format unmount** — diskutil unmounts cleanly before writing.
  `newfs_fskit` would race the live mount and corrupt the kernel
  buffer cache.
- **Partition map handling** — `eraseDisk` re-creates the partition
  map (we pass `GPT` explicitly), so blank/raw whole disks just work.
  `newfs_fskit` only does the filesystem-level format, which left
  blank disks unformattable through this path.
- **Re-probe + re-mount after** — diskutil re-probes the new volume
  and mounts it under `/Volumes/<name>`. `newfs_fskit` left the
  device in an unmounted state, requiring a manual remount.
- **Apple-blessed** — same code path Disk Utility.app's "Erase as
  ext4 / NTFS" dropdown uses. Our extension's Info.plist already
  declares `FSFormatOptionSyntax`, so we're discoverable.

## How the leaf actually works (extension side)

`FSManageableResourceMaintenanceOperations.startFormat(task:options:)`
in our `EXT4FileSystem` / `NTFSFileSystem` resolves the device via
the `mountedResources` map (same pattern `startCheck` uses), builds a
fresh `fs_*_blockdev_cfg_t` against the retained `BlockDeviceContext`,
and calls `fs_ext4_mkfs` / `fs_ntfs_mkfs`.

This works because `diskutil eraseDisk` opens the device and registers
it with FSKit *before* invoking the format. Our `loadResource` runs
first and populates `mountedResources`; then `startFormat` finds the
entry and writes the new filesystem. Blank disks work because diskutil
also drives the partition map creation, so by the time `startFormat`
fires, there's a fresh partition for our extension to format into.

The FSKit `startFormat` API doesn't pass an `FSResource` parameter
directly — see `FSResource.h` in the macOS 26.2 SDK. We work around
that with the `mountedResources` lookup, same trick `startCheck` uses.

## What works today

- Format a blank/raw whole disk: ✅ `diskutil eraseDisk` rebuilds the
  partition map and calls our extension to format the new partition.
- Format an existing mounted volume (replace the FS in place): ✅
  diskutil unmounts first, formats, re-mounts.
- Format a single slice without touching siblings: ✅ via
  `diskutil eraseVolume`.
- macOS `diskutil` CLI parity: ✅ same fstype names work from the
  command line.
- Disk Utility.app's "Erase as ext4 / NTFS" dropdown: ⚠️ likely works
  (Info.plist `FSFormatOptionSyntax` is declared) but not yet
  empirically tested.

## Known limitations / future work

1. **Volume name is hardcoded to `DJ-<fstype>`** in the host-app
   button handler. A name input field in the confirmation dialog is
   straightforward follow-up work.
2. **NTFS C ABI doesn't yet accept a label arg**
   (`fs_ntfs_mkfs(cfg)` hard-codes `None` even though the underlying
   Rust `format_filesystem` supports it). Extending the C export to
   `fs_ntfs_mkfs(cfg, label)` matches the ext4 shape and is a small
   change in `vendor/rust-fs-ntfs`.
3. **No partition manipulation UI yet** — the `Partition…` button is
   still disabled. `diskutil partitionDisk` is the obvious next
   target.
4. **No empirical confirmation Disk Utility.app sees us in its
   format dropdown.** Should be auto-discovered via Info.plist
   `FSFormatOptionSyntax`; needs a real-disk test to confirm.
