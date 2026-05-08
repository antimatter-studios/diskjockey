# Disk image format roadmap

Container formats DiskJockey could plug in. Each is a candidate
`rust-img-<name>` crate that exposes `fs_core::BlockDevice` so the
existing partition probe + filesystem drivers compose without
per-format glue.

Convention recap:
- GitHub repo: `antimatter-studios/rust-img-<name>`
- crates.io package: `am-img-<name>`
- lib name: `<name>` (so `use vhd::Reader`, `use vmdk::Reader`, ...)
- Trait surface: `impl fs_core::BlockRead [+ BlockDevice]`

## Status legend

- **Done** — implemented and tested
- **Planned** — committed, not yet started
- **Stretch** — useful but not blocking; pick up when one of the planned ones is in flight
- **Skip** — explicitly out of scope for now (legal/complexity/popularity)

## Catalog

| Format | Crate | Status | RO/RW priority | Notes |
|---|---|---|---|---|
| QCOW2 | `am-img-qcow2` | Done (RO) | RW next | Uncompressed + zlib + backing chain. Write path: refcount table + cluster alloc + crash-safety ordering. |
| Raw image | `am-img-raw` | Planned | RW trivial | `.img`, `.bin`, `.iso`-as-raw. Literally just `FileDevice` — could be a 30-line crate or skip and use `fs_core::FileDevice` directly. |
| VHD | `am-img-vhd` | Planned | RO first | Microsoft fixed/dynamic/differencing. Footer at end of file (fixed) or footer + dynamic header + BAT (dynamic). Differencing = backing chain analogue. |
| VHDX | `am-img-vhdx` | Planned | RO first | Modern Hyper-V format. 64 TB limit, log-structured metadata, larger sector sizes (4K). More complex than VHD. |
| VMDK | `am-img-vmdk` | Planned | RO first | VMware. Multiple subformats — monolithic-sparse, flat, stream-optimized, 2GbMaxExtent. Descriptor file (text) + extents (binary). Stream-optimized uses zlib per grain. |
| VDI | `am-img-vdi` | Stretch | RO | VirtualBox. Simpler than VMDK but smaller install base. Block map + fixed-size data blocks. |
| DMG | `am-img-dmg` | Stretch | RO | Apple. Complex: KOLY trailer + property list + UDIF blocks (raw / zlib / bzip2 / lzfse / lzma). Often contains HFS+ or APFS — needs those drivers downstream. |
| sparseimage | `am-img-sparseimage` | Stretch | RO first | Apple single-file sparse. Band-based allocation similar in spirit to qcow2 clusters. |
| sparsebundle | `am-img-sparsebundle` | Stretch | RO first | Apple directory-based. Each band is a separate file under `bands/` — handy for incremental backup. Time Machine on network volumes uses this. |
| ISO 9660 | `am-img-iso` | Stretch | RO only | Optical media. Also a *filesystem*, so could live as `am-fs-iso9660` under the fs-* family instead. Decision: container if the consumer mainly wants a flat byte stream, fs if they want to walk the directory tree. Probably fs. |
| UDF | `am-img-udf` | Stretch | RO first | Universal Disk Format. DVD/Blu-ray + a few odd USB drives. Same fs-vs-container dilemma as ISO. |
| SquashFS | `am-fs-squashfs` | Stretch | RO only | Compressed read-only fs. Belongs in fs-* family, not img-*. Linux live ISOs and embedded systems. |
| QCOW (v1) | — | Skip | — | Original qemu format. Superseded by qcow2 ~15 years ago. Not worth the bytes. |
| QED | — | Skip | — | QEMU Enhanced Disk. Abandoned by upstream qemu. |
| Parallels HDD | `am-img-phd` | Skip | — | Spec partially reverse-engineered. Small install base. Revisit only if a user asks. |
| CHD | — | Skip | — | MAME/emulator format. Not relevant to filesystem mounting. |

## Format brief

### QCOW2 ([am-img-qcow2](https://github.com/antimatter-studios/rust-img-qcow2))

Already shipped. Spec: <https://github.com/qemu/qemu/blob/master/docs/interop/qcow2.txt>.
Outstanding work captured separately:

- Write support (refcount table + cluster allocation + crash-safety
  ordering)
- Internal snapshots (read first, then create)
- zstd compression (refused at header check today)
- External data file (refused at header check today)
- LUKS-encrypted qcow2 (refused at header check today)

### Raw image (`.img`, `.bin`, `.iso`-as-raw)

A regular file with no header. `fs_core::FileDevice::open` already
handles this. A dedicated `am-img-raw` crate could add MIME-style
extension detection + size validation, but it's borderline pointless
since `FileDevice` already exposes `BlockRead/BlockDevice`.

**Recommendation:** don't create a crate. Document in DiskJockey that
raw images are opened via `fs_core_file_open`.

### VHD (`.vhd`)

Microsoft Virtual Hard Disk. Three sub-types:

- **Fixed** — file = data + 512-byte footer at end. Trivial.
- **Dynamic** — header at start, dynamic header at +512, BAT (Block
  Allocation Table), then sparse data blocks. 2 MB block default.
- **Differencing** — like dynamic but with a parent VHD reference;
  unset BAT entries defer to parent. Direct analogue of qcow2 backing.

Spec: <https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2008-R2-and-2008/dd323654(v=ws.10)>
or the original Microsoft VHD whitepaper.

### VHDX (`.vhdx`)

VHD's successor. Larger limits (64 TB), log-structured metadata for
crash safety, 4K sector support, optional resilient change tracking.
More complex than VHD but the read path is approachable. Used by
Hyper-V, WSL2 distro storage.

Spec: <https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-vhdx/>.

### VMDK (`.vmdk`)

VMware. Confusing because "a VMDK" can be one of several things:

- **Monolithic flat** — descriptor + one big binary extent. Trivial.
- **Monolithic sparse** — descriptor + grain table + grain directory.
- **2GbMaxExtent** sparse/flat — split across many `*-s001.vmdk` files
  for FAT32 compat.
- **Stream-optimized** — sparse + zlib-per-grain. The format VMware
  uses for OVF / OVA distribution.

The descriptor is a UTF-8 text file. Easiest entry point: parse the
descriptor, then dispatch to the relevant extent reader.

Spec: <https://developer.vmware.com/web/sdk/8.0/virtual-disk-development-kit>
(VMDK technical note, free PDF).

### VDI (`.vdi`)

VirtualBox. Header + image type (fixed/dynamic) + block map + data.
Much simpler than VMDK. Lower priority because VirtualBox usage has
declined; users with VDIs often have qcow2 or VMDK alongside.

Spec: <https://forums.virtualbox.org/viewtopic.php?t=8046> (community
write-up; VirtualBox source is the authoritative reference).

### DMG (`.dmg`)

Apple disk image. Hardest to support cleanly:

- KOLY trailer (512 bytes) at end of file
- XML property list (`plist`) embedded with UDIF block table
- Compressed blocks: raw, zlib (`adc`), bzip2, LZFSE, LZMA
- Often contains HFS+ or APFS — those drivers must exist downstream
- May be encrypted (PBKDF2 + AES-128/256) or signed

Plan: defer until the HFS+/APFS readers exist, then layer DMG on top.

### sparseimage / sparsebundle

Apple sparse formats:

- `sparseimage` — single file, band-based allocation. Headers similar
  to encrypted disk images.
- `sparsebundle` — directory containing `Info.plist`, `token`, and a
  `bands/` subdirectory of fixed-size files, one per allocated band.
  Time Machine on network targets uses this.

Both wrap an HFS+ or APFS volume. Same downstream-driver
prerequisite as DMG.

## Cross-cutting concerns

### Backing / parent chains

QCOW2 (already done), VHD differencing, VHDX differencing, VMDK
linked clones, DMG with parent — all want the same chain abstraction.
Worth factoring once a second one lands: a `BackingChain<T>` adapter
in `fs-core` that consumes any `BlockRead` and a parent-resolution
callback.

### Compression backends

QCOW2 uses zlib (raw deflate). VHDX optional, VMDK stream-optimized
uses zlib too. DMG layers in bzip2 / LZFSE / LZMA. Standardising on
`flate2` for zlib is fine; LZFSE needs `lzfse` crate or hand-roll;
bzip2 needs `bzip2` (links libbz2 — check MAS sandbox). LZMA via
`xz2`.

### Write support cost

For RW container support, each format duplicates the same problem:
allocate new clusters/blocks/grains, update the allocation map,
order writes for crash safety. The pattern is identical across
QCOW2 / VHD / VHDX / VMDK. After the first one is shipped, the
others are mostly format translation.

## Out-of-scope (deeper layers, captured for completeness)

These aren't disk-image formats but live in the same neighbourhood
and may want crates eventually:

- **LUKS** — Linux disk encryption. Fits as `am-block-luks` (consumes
  a `BlockRead`, emits a decrypted `BlockRead`). Needs AES-XTS.
- **LVM2** — Linux volume management. Volume group → logical volumes
  inside a partition. `am-block-lvm`.
- **mdraid** — Linux software RAID. `am-block-mdraid`.
- **ZFS** — its own universe. Skip; user says use OpenZFSonOSX.
- **Btrfs / F2FS** — filesystems, not images. Belong in `am-fs-*`.

## When to revisit

Check this doc at the start of any session that mentions:

- "Mount a `.vhd|.vhdx|.vmdk|.vdi|.dmg`"
- "Read a Hyper-V / VMware / VirtualBox / Parallels disk"
- "Time Machine sparsebundle"
- "Browse a Windows VM disk on a Mac"

Each is a green-field crate using the same shape as `am-img-qcow2`:
header parser → block-mapping table → `BlockRead`/`BlockDevice` impl
→ C ABI returning `FsCoreDevice*`.
