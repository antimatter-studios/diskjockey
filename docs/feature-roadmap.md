# Feature roadmap

Living list. Items sorted within each tier by impact × feasibility.
"Done" entries stay listed for reference. New ideas append at the
bottom of their tier.

## Tier 1 — high impact, fully autonomous

- [ ] **NTFS C ABI parity** — `fs_ntfs_mount_with_fs_core_device` matching
      what ext4 just got. Single entry point that takes any
      `FsCoreDevice*` (qcow2 slice, raw file, callback) and produces an
      `fs_ntfs_t*`. Closes the cross-crate handle parity gap.
- [ ] **qcow2 refcount decrement on cluster replacement** — currently
      Phase C compressed-rewrite leaks the old compressed cluster.
      Add `decrement_refcount(host_off)` and call it after
      `update_l2_entry` for any non-shared cluster. Eliminates leaks
      without snapshot CoW.
- [ ] **`SliceReader` → fs-core** — currently in `am-partitions`, but
      slicing is a generic block-layer concern. Move to fs-core so
      any consumer (not just partition probe users) can grab it. Keep
      a re-export in partitions for backwards compat.
- [ ] **Read-only safety wrapper `ReadOnlyDevice<T>`** — wraps any
      `BlockDevice`, rejects writes, returns `is_writable() -> false`
      regardless of inner. Useful for "give me this image RO with
      type-level certainty" scenarios. ~30 LOC + tests.

## Tier 2 — new image-format readers

- [ ] **`am-img-vhd`** — Microsoft VHD (fixed/dynamic/differencing).
      Footer at end-of-file (fixed) or footer + dynamic header + BAT
      (dynamic). Differencing is direct analogue of qcow2 backing
      chain. Spec: Microsoft VHD whitepaper.
- [ ] **`am-img-vhdx`** — VHD's modern successor, used by Hyper-V and
      WSL2. Larger limits, log-structured metadata. More complex than
      VHD but read path is approachable. Spec: MS-VHDX.
- [ ] **`am-img-vmdk`** — VMware. Multiple subformats: flat,
      monolithic-sparse, 2GbMaxExtent, stream-optimized. Descriptor
      file (text) + extents (binary). Stream-optimized uses zlib per
      grain. Spec: VMware VMDK technical note (free PDF).
- [ ] **`am-img-vdi`** — VirtualBox. Simpler than VMDK; smaller
      audience. Header + image type + block map + data.
- [ ] **`am-img-raw`** — wrapper around `fs_core::FileDevice` for
      `.img`/`.bin`/`.iso`-as-raw. Borderline pointless as a separate
      crate; may instead document "use fs_core_file_open directly".

## Tier 3 — utilities and architectural

- [ ] **`am-disk-inspect` CLI** — single binary. `inspect <path>` →
      JSON report: container format, virtual size, partition table,
      partitions with FS sniff. `inspect --human` for tabular
      pretty-print. Bundles dependencies on every img/probe/sniff
      crate. Replaces the per-crate `inspect` examples.
- [ ] **GPT primary/backup mismatch detection** — currently we parse
      only the primary GPT (LBA 1). Read the backup at `n-1`,
      compare. Report mismatches as `Error::GptMismatch { primary,
      backup }`. Useful for diagnosing partial-write damage.
- [ ] **Extended MBR (logical partition) chain walking** — current
      MBR parser stops at the four primaries; type 0x05/0x0F entries
      are reported as-is rather than walked. Walk the chain, surface
      logicals.
- [ ] **fs-core `Logger` hook** — pluggable `set_logger(callback)`
      function. Crates emit events through it; default is no-op. Lets
      DiskJockey or a CLI route diagnostics to its existing log
      sink without each crate hard-coding a logging dependency.
- [ ] **fs-core `IoStats` hook** — counters for reads/writes,
      bytes-read/bytes-written, cache hit rate. Exposed by
      `CachingDevice` already; generalise across every adapter.

## Tier 4 — filesystem readers (Rust-only, ship as fs-* crates)

- [ ] **`am-fs-squashfs`** — read-only compressed FS, used by Linux
      live ISOs and embedded systems. Spec: SquashFS source headers.
- [ ] **`am-fs-iso9660`** — optical media. Old, simple, still
      relevant for Linux installer ISOs. Spec: ECMA-119.
- [ ] **`am-fs-fat32`** / **`am-fs-fat16`** — small-disk Mac/Win/Linux
      common ground. Read-only first (write later). Spec: Microsoft
      FAT specification.
- [ ] **`am-fs-exfat`** — modern FAT successor, used on big SD cards
      and external drives. Apple ships it natively but a
      hand-rolled impl gives cross-platform parity (Windows/Linux
      drivers).
- [ ] **`am-fs-hfsplus`** — read-only browse of legacy Mac disks.
      Pre-2017 Time Machine sparsebundles, old USB drives.

## Tier 5 — block-layer composition

- [ ] **`am-block-luks`** — Linux disk encryption header parser +
      AES-XTS decryption layer. Lets us browse encrypted Linux
      partitions inside qcow2. Spec: cryptsetup LUKS2 docs.
- [ ] **`am-block-lvm`** — Linux LVM2 volume groups → logical volumes
      inside a partition. Spec: LVM2 metadata format.
- [ ] **`am-block-mdraid`** — Linux software RAID superblock parser.

## Tier 6 — write paths for everything (do these one driver at a time)

- [ ] **qcow2 Phase D — snapshot CoW** — when `nb_snapshots > 0`,
      check refcount per cluster, copy-on-write before writing
      shared clusters. Substantial spec work.
- [ ] **qcow2 Phase D — refcount-block growth** — when existing
      blocks are full, allocate a new refcount block + table slot.
      Currently fails with `Unsupported`.
- [ ] **VHD writes** — fixed RW is trivial; dynamic RW needs BAT
      updates with crash-safety ordering.
- [ ] **VHDX writes** — log-structured metadata makes crash safety
      cleaner than qcow2; complexity is in the log replay logic.

## Tier 7 — DiskJockey-side (host app) features

- [ ] **Open-with-qcow2 file picker** — drag a qcow2 onto the
      DiskJockey window or pick via NSOpenPanel. Calls
      `qcow2_open` + `partitions_probe`, shows partition list with
      FS labels.
- [ ] **Mount-as-volume button per partition** — once the FSKit URL
      resource path is implemented (see
      `fskit-disk-image-mount-architecture.md`), this becomes the
      "click qcow2 → see Finder volumes" flow.
- [ ] **Volume-name display from FS metadata** — sniff returns
      `FsKind`; extend to also read the volume label (NTFS volume
      name, ext4 `s_volume_name`, FAT volume label) so the UI can
      show "Windows" / "rootfs" / etc. instead of "ext4 partition".
- [ ] **Aggregate eject** — eject a qcow2 unmounts every child
      volume, closes every fs handle, drops the qcow2.
- [ ] **Recently-opened images** — sidebar list of qcow2/vhd/vmdk
      paths the user has touched, security-scoped bookmarks for
      reopening.

## Tier 8 — stretch / future

- [ ] **Async I/O surface** — long writes (compressed cluster
      decompress + rewrite) want async cancellation. Add tokio (or
      futures-only) optional features.
- [ ] **Network filesystem readers** — NFS, SMB, WebDAV, SFTP at the
      BlockRead/FS layer. Pairs with the existing go-networkfs
      cloud drivers.
- [ ] **Metadata-only scan** — enumerate paths in an unmounted ext4
      / ntfs / fat without serving an FSKit volume. Forensic /
      backup tooling.
- [ ] **APFS read** — biggest spec lift in this list; let through
      DMG support eventually.
- [ ] **DMG** — depends on HFS+/APFS read existing.

## Done

- [x] Trait unification (`fs-core`) — `BlockRead` / `BlockDevice` +
      adapters, C ABI with handle + error codes + last-error TLS.
- [x] qcow2 reader — uncompressed + zlib + backing chain + sparse +
      v3-zero, Phase A/B/C writes (allocated/sparse/compressed).
- [x] partition probe — GPT (CRC validated) + MBR + 10-FS sniff +
      slice adapter, C ABI.
- [x] ext4 ↔ fs-core bridge module — bidirectional, additive,
      strictly safe.
- [x] ext4 C ABI — `fs_ext4_mount_with_fs_core_device`.
- [x] ntfs ↔ fs-core bridge module — inbound `CoreDevice<T>` adapter.
- [x] commit / pr Claude Code skills + worktree-on-WIP pattern.
- [x] FSKit research blueprint — `FSPathURLResource` is the path.

## Mode of operation

Whenever a tier-1 or tier-2 item ships, mark `[x]` and add a one-line
"how it shipped" note. New ideas append at the bottom of the relevant
tier. Items deferred for spec or architecture work get a one-line
reason, not abandoned.

## Overnight queue (in order)

Committed scope — implement, test, clippy-clean, mark off. If
something blocks (spec ambiguity, runtime issue) note it and move on.

### Phase 1 — Tier 1 foundations (~1 hour equiv)

1. **NTFS C ABI: `fs_ntfs_mount_with_fs_core_device`** — single entry
   point taking any `FsCoreDevice*`, mirroring the ext4 entry point.
2. **`SliceReader` → fs-core** — move from `am-partitions` to
   `am-fs-core`; partitions re-exports for backwards compat.
3. **`ReadOnlyDevice<T>` wrapper in fs-core** — wraps any
   `BlockRead`/`BlockDevice`, rejects writes regardless of inner.
4. **qcow2 refcount-decrement on cluster replacement** — Phase D
   cleanup so compressed-rewrite no longer leaks.

### Phase 2 — `am-img-vhd` reader (~2 hours equiv)

5. Scaffold `vendor/rust-img-vhd` crate (Cargo.toml, LICENSE,
   README, .gitignore, rust-toolchain.toml).
6. Footer parser (512-byte trailer, magic "conectix", checksum).
7. Dynamic header parser (location 1024 from start when type is
   dynamic/differencing), BAT (Block Allocation Table) walking.
8. `VhdReader` exposing `fs_core::BlockRead + BlockDevice` for fixed
   and dynamic VHDs.
9. Differencing chain (parent VHD lookup, fall-through reads —
   direct analogue of qcow2 backing).
10. C ABI `vhd_open(path) -> *mut FsCoreDevice` + header.
11. Synthetic fixtures + tests (fixed, dynamic, differencing).
12. `inspect` example demonstrating vhd → partitions → sniff stack.

### Phase 3 — `am-img-vhdx` reader (~2.5 hours equiv, if time)

13. Scaffold `vendor/rust-img-vhdx`.
14. File identifier ("vhdxfile") + region table parser.
15. Metadata table (file parameters, virtual disk size).
16. BAT walking with sector bitmap support.
17. `VhdxReader` read path.
18. C ABI + tests.

### Phase 4 — `am-img-vmdk` reader (basic flat + sparse, ~2 hours equiv, if time)

19. Scaffold `vendor/rust-img-vmdk`.
20. Descriptor file parser (text-based key=value).
21. Flat extent reader (trivial pass-through).
22. Sparse extent reader (grain table + grain directory).
23. C ABI + tests.
24. Stream-optimized format deferred (zlib-per-grain — Phase 5).

### Phase 5 — `am-img-raw` and inspect CLI (~1 hour equiv, if time)

25. `am-img-raw` — minimal wrapper, mostly documentation.
26. `am-disk-inspect` consolidated CLI — single binary that dispatches
    to the right reader by extension/magic, dumps JSON.

### Skipped from this overnight

- DMG, sparseimage, sparsebundle — depend on HFS+/APFS which we
  don't read yet.
- VDI — lower priority than VHD/VHDX/VMDK; pick up once those land.
- qcow2 Phase D snapshot CoW — substantial spec work, defer.
- Any Swift / FSKit work — needs hands-on testing.

Each phase ends with: full crate `cargo test` green + `cargo clippy
-D warnings` clean + a synthetic-image integration test that
exercises the reader through the C ABI.

