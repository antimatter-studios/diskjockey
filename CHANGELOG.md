# Changelog

Reverse-chronological history of DiskJockey, distilled from `git log`. Cascade auto-snapshot commits are omitted; only intent-bearing commits are listed. Breakthroughs and architectural pivots are highlighted.

The README carries an abbreviated tail of this file (last ten dated sections).

---

## 2026-06-02

- **`NTFSBlockDeviceContext` migrated onto shared `BlockDeviceContext`.** Closes the follow-up flagged at the bottom of PR #24 — `DiskJockeyNTFS/NTFSFileSystem.swift` kept its own ~155-line copy of the FFI bridge context with an in-process read cache that the shared `BlockDeviceContext` (in DiskJockeyLibrary, used by EXT4) didn't have. Rather than fork the shared type or subclass, parameterised it via init options (all defaults preserve EXT4 behaviour): `stats: IOStatsCollector?` (relaxed to optional so NTFS's brief probe context can omit it), `writeStrategy: .delayed | .immediate` (EXT4 stays on `delayedMetadataWrite`, NTFS picks `metadataWrite` for synchronous commit), `readCache: BlockReadCache?` (opt-in cache; NTFS passes a 512-entry instance to dodge the boot-sector + $UpCase refetch storm the rust crate's mutator path triggers), `alignToPhysicalBlockSize: Bool` (EXT4 keeps `max(logical, physical, 512)`, NTFS uses `max(logical, 512)`). New `public final class BlockReadCache: @unchecked Sendable` in `DiskJockeyLibrary/BlockReadCache.swift` with true LRU eviction (slight behaviour upgrade from the original `removeAll-when-full` — same total capacity, smarter retention of the hot working set). All ~30 `Unmanaged<NTFSBlockDeviceContext>.fromOpaque(...)` call sites become `Unmanaged<BlockDeviceContext>.fromOpaque(...)`; the `NTFSContainerKind.detect(context:)` signature updates to take the shared type. Twelve new tests in `DiskJockeyLibraryTests/BlockReadCacheTests.swift` pin: empty lookup, insert round-trip, re-insert replace, distinct-keys independence, range-overlap invalidation (the load-bearing NTFS-correctness path — overlapping writes must invalidate; non-overlapping ranges stay cached), invalidate-all-via-large-range, LRU eviction at cap, lookup-bumps-recency, re-insert-bumps-recency, removeAll, and 200-key concurrent insert/lookup/invalidate stress. Library suite 45 XCTest + 14 Swift Testing = 59 green; app suite 101 green; total 160. NTFS write semantics (`metadataWrite`) and read-cache behaviour preserved exactly; EXT4 paths unchanged (defaults match its previous behaviour bit-for-bit).


- **`EXT4FileSystem.swift` decomposed across 5 files; device contexts promoted to DiskJockeyLibrary.** The 1417-line class file had three concerns tangled together: the FSKit pipeline methods (`probeResource`, `loadResource`, `unloadResource`, `startCheck`, `startFormat`) on the orchestration side, the FFI bridge contexts (`BlockDeviceContext` for `FSBlockDeviceResource`, `FileDeviceContext` for `FSPathURLResource`) wrapping the C-callback shape `fs_ext4_blockdev_cfg_t` / `FsCoreCallbackCfg` expect, and the maintenance ops + format pretty-printers. Now split into five files by responsibility: `EXT4FileSystem.swift` (class skeleton, statics, `MountedResource`, `watchdog`, init, `taskOption` + format-display helpers, `MountableFileSystem` conformance — ~210 lines), `EXT4Probe.swift` (`probeResource` / `probeFileResource` / `ContainerKind` / `detectContainer<C>` — ~225 lines), `EXT4Load.swift` (`loadResource` / `loadFileResource` / `unloadResource` / `buildFsCoreHandle` / `openContainer` — ~430 lines), `EXT4Maintenance.swift` (the existing `FSManageableResourceMaintenanceOperations` extension + `FsckProgressTracker` — ~340 lines), plus `DiskJockeyLibrary/DeviceContexts.swift` carrying `DeviceReadable` + `BlockDeviceContext` + `FileDeviceContext` (~225 lines, made `public`) so future filesystems can reuse the same FFI bridges without forking. All method bodies move verbatim — zero behaviour change. Access modifiers widen from `private` to default `internal` for the four cross-file helpers (`detectContainer`, `taskOption`, `buildFsCoreHandle`, `openContainer`, `formatXxx`); `probeFileResource` / `loadFileResource` stay `fileprivate` since their callers stay in the same file. Three new pbxproj entries added for the EXT4 files (DiskJockeyEXT4 is an explicit PBXGroup); `DeviceContexts.swift` slots into the synchronized DiskJockeyLibrary group without project edits. No new tests for this item — pure file-split with zero new code paths; the existing 148-test contract (101 DiskJockeyTests + 33 DiskJockeyLibraryTests XCTest + 14 Swift Testing) staying green is the behaviour-preservation pin.


- **Repair file-watcher consolidated into shared `RepairWatcher` in DiskJockeyLibrary.** `DiskJockeyEXT4/RepairXPCService.swift` (343 lines) and `DiskJockeyNTFS/RepairXPCService.swift` (204 lines) each kept a near-identical file-based-XPC scaffold — same `start()` idempotency lock, same `DispatchSource` on the requests-dir FD, same atomic-rename-as-claim, same JSON decode + filename-UUID fallback, same atomic result write. Now there's one `public final class RepairWatcher: @unchecked Sendable` in `DiskJockeyLibrary/RepairWatcher.swift` that owns all of that; each per-target `RepairXPCService` shrinks to a thin adapter that supplies only the genuine per-FS variation (`runRepair` closure body, optional watchdog enter/exit hooks, `workQueueLabel`). EXT4 keeps its ~50-line throttled-fsck `runRepair` body verbatim (with `EXT4FileSystem.watchdog.heartbeat()` and the `OperationLock` tri-state acquire/release intact); NTFS's wrapper is now ~50 lines including a 5-line stub `runRepair` that returns the truthful "not implemented yet" response. Net effect: 343 + 204 = 547 lines of duplicated scaffolding collapse to 269 lines of shared library + 130 EXT4 wrapper + 60 NTFS wrapper. NTFS's mixed log scopes (`.lifecycle` for scaffolding events, `.fsck` only inside `runRepair`) normalised to `.fsck` throughout — matches EXT4's posture and the actual meaning (repair IS fsck pipeline activity); tiny intentional log-routing tweak, not user-visible. Six new tests in `DiskJockeyLibraryTests/RepairWatcherTests.swift` drive `handleRequest(at:)` directly against temp App-Group-shaped dirs: happy-path decode + runRepair invocation + result write, malformed-JSON-with-parseable-UUID-filename writes failure result (so the host doesn't wait the full polling timeout), malformed-JSON-with-unparseable-filename writes nothing (current behaviour preserved), enter/exit hook bracket fires exactly once around handleRequest including on decode failure (critical for EXT4's watchdog counter balance), runRepair failure result is round-tripped verbatim. Full library suite 33/33 + 14 Swift Testing green; app suite 101/101 green.
- **`AttachedDisksModel` decomposed into `MountTableParser` + `DiskEventHandler`.** The 855-line `@MainActor` model had three concerns tangled together: `/sbin/mount` subprocess + statvfs + parsing (~150 lines), structured-event → state transforms (~120 lines), and the orchestration / `@Published` store itself. The two helper concerns are now `enum MountTableParser` and `enum DiskEventHandler` in `DiskJockeyApplication/Models/` — namespace-style (case-less `enum`) so they can't be instantiated and no state can leak in. `AttachedDisksModel.refresh()` and `applyExtensionEvent` now delegate to those namespaces with one-line calls; the model's public API is unchanged. The existing `AttachedDisksModelTests` updates one call site (`AttachedDisksModel.parseMountLine` → `MountTableParser.parseMountLine`) — that the test still passes after the rename is the proof of behaviour preservation. New `DiskJockeyTests/MountTableParserTests.swift` (11 cases) covers parseMountLine for RW / RO / legacy-RO / fstype-filter / malformed-line / NTFS, bsdName extraction (both dev-prefixed and bare), and isWholeDiskBSD on bare disks / slices / malformed input including the `disk` edge case the original regex rejects. New `DiskJockeyTests/DiskEventHandlerTests.swift` (17 cases) covers fsTypeFromEventKind for known and unknown prefixes, fsckStatus dispatch across every kind (volume.clean / dirty / fsck.start / fsck.progress / fsck.done / fsck.failed / unknown), applyVolumeInfo (fs adoption, volume_name placeholder rule, volume_name clobber-protection, stableIdentity from UUID + from ntfs serial), materializeTotalSize (ext4 multiply / ntfs passthrough / unknown / overflow), and applyEventInPlace dispatch (volume.info → volume handler / fsck.progress → fsckStatus / unknown kind no-op). Full app + library suites still green (139 tests across both).
- **`MountableFileSystem` protocol + `MountedResourceRegistry<R>` generic.** EXT4FileSystem and NTFSFileSystem each declared `static let mountedResources = OSAllocatedUnfairLock<[ObjectIdentifier: MountedResource]>(initialState: [:])` and reimplemented the same four ops against it: register on load, remove on unload, resolve-the-sole-entry for `startCheck`/`startFormat`, and find-by-bsdName for the RepairXPCService. Same shape, two byte-near-identical implementations. Now there's one `public final class MountedResourceRegistry<Resource: MountedResource>: @unchecked Sendable` in `DiskJockeyLibrary/MountableFileSystem.swift`, exposing `register(_:_:)` / `remove(_:)` / `resolveSingle()` / `first(where:)` / `count` — the four operations the callers actually do, each one line at the call site. Plus `protocol MountedResource` (codifies the shared `bsdName + opLock` fields the per-FS structs already had) and `protocol MountableFileSystem` (associates each FS class with its registry handle). Twelve raw `withLock { map in … }` blocks collapse to one-line API calls; both `EXT4FileSystem.MountedResource` / `NTFSFileSystem.MountedResource` adopt the library protocol with zero field changes; both classes carry an `extension … : MountableFileSystem {}` conformance. Eight new tests in `DiskJockeyLibraryTests/MountableFileSystemTests.swift` cover register / replace / remove / idempotent-remove / `resolveSingle` ambiguity refusal / `first(where:)` predicate / concurrent 100-key register-and-remove / a stand-in `MountableFileSystem` conformance that proves the associated-type machinery compiles independent of the FSKit-extension targets. Full library suite 41/41 green.
- **Per-volume item cache extracted into reusable `FileIDCache<Item>`.** Both `EXT4Volume` and `NTFSVolume` carried a `[UInt64: Item]` map with the same get-or-create-or-replace shape (validate cached entry's path + parentID; replace if mismatch — the load-bearing guard against inode reuse + hard-link aliasing + rust-fs-ext4 mkdir-reused-fileID). EXT4 used `OSAllocatedUnfairLock`; NTFS used `NSLock`. Now there's one `public final class FileIDCache<Item: AnyObject>` in `DiskJockeyLibrary/FileIDCache.swift`, backed by `OSAllocatedUnfairLock` — NTFS upgrades from `NSLock` to the modern Sendable-correct primitive as a side effect. API is `getOrCreate(id:validate:create:)` + `remove(id:)` + `count`; the per-FS validation rule (path + parentInode for ext4, path + parentRecordNumber for NTFS) lives in the caller's closure so the cache stays oblivious to per-flavour invariants. Net change inside the volumes: `item(forID:)` / `item(forRecordNumber:)` bodies collapse from a manual `withLock { … }` block to a single `items.getOrCreate(…)` call; `reclaimItem` collapses to `items.remove(id:)`. Eight new tests in `DiskJockeyLibraryTests/FileIDCacheTests.swift` cover empty-cache create, validate-true hit, validate-false replace, distinct-keys independence, removal, no-op remove on absent id, and concurrent stress (200 / 500 parallel calls). Full library suite 33/33 green.
- **`EXT4Item` / `NTFSItem` collapsed into generic `FileSystemItem<Tag>`.** The two per-FS classes (37 + 36 lines) were structurally identical — an identity value, a path, an optional parent identity — diverging only in the integer width of the identity (`UInt32` inode vs `UInt64` MFT record). Now there's one `open class FileSystemItem<Tag: FileSystemTag>: FSItem` in `DiskJockeyLibrary/FileSystemItem.swift`, with `EXT4Tag` / `NTFSTag` phantom markers pinning the identity width per filesystem. Call sites in `EXT4Volume` / `NTFSVolume` keep their familiar `inode` / `parentInode` / `fileRecordNumber` / `parentRecordNumber` spelling via tag-constrained extensions that forward to the generic storage — the volume code didn't change. Phantom-tag distinctness means a stray cast can no longer feed an ext4 inode into an NTFS code path; the compiler refuses it. Eleven new unit tests in `DiskJockeyLibraryTests/FileSystemItemTests.swift` cover init round-trip, legacy forwarders, ID widths, root (parent=nil) shape, and static type distinctness; full library suite 25/25 green.
- **AppLog deduplication.** Four byte-identical copies of `AppLog.swift` (345 lines each, total 1,380 lines) lived in DiskJockeyEXT4, DiskJockeyNTFS, DiskJockeyFileProvider, and DiskJockeyApplication. Now there's one canonical copy in `DiskJockeyLibrary/AppLog.swift`. Each consumer reaches it through the `import DiskJockeyLibrary` line they already had. Net deletion ~1,035 lines (1,380 removed, 345 moved into the library). Four `import DiskJockeyLibrary` lines added to files that previously relied on AppLog being in the same module (MountErrorReporter, ThumbnailCache, OAuthClientConfig, OAuthCoordinator). Eight `.pbxproj` entries dropped for the two targets that had explicit file references (EXT4 + NTFS); the other two used synchronized folders and needed no project edit. Tests: 81/81 still green.

## 2026-05-31

- **EXT4 stuck-progress watchdog (Fix D).** `DetachedOperationWatchdog` gains a per-op heartbeat layer on top of the existing deactivate-side trigger from Fix A. While a fsck / repair / format op is in flight, a background timer wakes once per `stuckCheckInterval` and checks whether `heartbeat()` has fired within `stuckDeadline` (default 60 s); if not, the same `onExpire` callback runs as Fix A's deactivate path — production exits the appex so `storagekitd` respawns. `EXT4FileSystem.startCheck` and `RepairXPCService.runRepair` call `watchdog.heartbeat()` from each Rust `onProgress` callback (unthrottled — log emission stays throttled separately, but the watchdog must see every tick). Catches the case where a verify/repair wedges mid-walk on a corrupted inode loop with no progress callbacks and the volume's still mounted — Fix A's deactivate-only trigger wouldn't fire there. Four new unit tests cover heartbeat-resets-clock, fires-when-silent, stays-quiet-while-beating, and stops-on-counter-zero.

## 2026-05-20

- **EXT4 quiesce during verify / repair (Fix C).** While `fsck_fskit -t ext4` (verify) or `RepairXPCService` (repair) holds the volume's `OperationLock`, every user-facing FS op in `EXT4Volume` (attributes, setAttributes, lookup, enumerateDirectory, read, write, readSymbolicLink, createItem, createSymbolicLink, createLink, removeItem, renameItem, synchronize) checks `opLock.current` as its first instruction and throws `POSIXError(.EBUSY)` immediately if non-idle. Finder, Spotlight, `cp` and other callers get a fast recognisable "disk in use" error instead of blocking on the backend lock for the entire verify duration. Verify itself doesn't traverse these gates — its dispatch goes `startCheck` → `backend.runFsck` → `fs_ext4_fsck_run` and reads the device internally via the Rust crate's private methods, so the quiesce never locks the holder out of its own work.
- **EXT4 streaming writes (Fix B).** `EXT4Volume.writeImpl` now uses `fs_ext4_pwrite` instead of the old whole-file `fs_ext4_write_file` + read-modify-write dance. Drops the O(N²) write cost (a 10 MB copy used to do ~1 GB of I/O) and removes the journal-descriptor-block overflow at the 1 MiB boundary — copying a >1 MiB file to a mounted ext4 volume used to cap at exactly 1 MiB with the rest zero-filled. Verified end-to-end with a 3.1 MB PNG round-trip.
- **EXT4 parent-death watchdog (Fix A).** `DetachedOperationWatchdog` (new, in `DiskJockeyLibrary`) tracks long-running fsck / repair / format `Task.detached` work. When the volume is deactivated with the counter non-zero, a 30-second timer arms; if still non-zero on expiry the appex `exit(EX_TEMPFAIL)`s so `storagekitd` respawns it cleanly. Stops the wedge where an orphan EXT4 appex pegs CPU for hours after the host app dies, blocking every other StorageKit consumer on the Mac (Disk Utility et al). Eight unit tests cover counter arithmetic + fire / no-fire scheduling.
- **EXT4 `i_crtime` on file / dir / symlink create (Fix E, via `rust-fs-ext4` 0.2.1).** Freshly created files now have a real `st_birthtime` instead of the Unix epoch (Finder no longer shows "1 January 1970" as the Created date). All four inode builders write the field at offset 0x90 when `i_extra_isize` covers it; ext2/3 128-byte inodes stay untouched.
- **Per-crate static libs for disk-image container readers.** `qcow2` / `vhd` / `vhdx` / `vmdk` each build to their own universal `.a` under `lib/img_<name>/` via the new `scripts/build-img-containers.sh`; DiskJockeyEXT4 and DiskJockeyNTFS link each via `OTHER_LDFLAGS`. Previously they were bundled into `libfs_ext4.a` and `libfs_ntfs.a` through a Cargo dep + `use ... as _` force-retain trick — wrong layering (a filesystem driver has no business reaching into image-format readers) that briefly shipped in `fs-ext4` 0.2.0 / `fs-ntfs` 0.2.0 before rollback. The static-lib link contract is now clean: each crate's `.a` carries only its own symbols.
- **Pre-commit hooks across the family.** Diskjockey grew `.githooks/pre-commit` (garbage-file guard, large-binary guard, trailing-whitespace check against `git diff --cached --check`) + `scripts/install-hooks.sh`. Activated across all 9 vendor crates (siblings + diskjockey-submodule git dbs), where they run `cargo fmt --check` + `cargo clippy --all-targets -- -D warnings`. The same drift that broke `rust-fs-ext4` CI mid-session can no longer escape locally.
- **`rust-fs-ext4` release pipeline hardening.** Workflow now uses `cargo publish --locked` instead of relying on cargo to silently update `Cargo.lock` during publish-verify. A bumped Cargo.toml without a matching `cargo update --workspace` now fails the release immediately with a clear "lockfile out of sync" message instead of either auto-fixing it (allowed) or failing on the dirty-tree check. First clean publish of `fs-ext4` 0.2.1 to crates.io as a result.
- **Family-wide vendor bumps.** `vendor/rust-fs-core` → 0.2.0 (`e2041e3`), `vendor/rust-img-qcow2` → 0.3.2 (`c891128`), `vendor/rust-img-vhd` / `vhdx` / `vmdk` → 0.2.0, `vendor/rust-partitions` → 0.3.0 (`00ce093`), `vendor/rust-fs-ext4` → 0.2.1 (`c3b0f8a`). `vendor/rust-disk-probe/Cargo.toml` bumped its `am-fs-core` constraint from `"0.1"` to `"0.2"` to match.

## 2026-05-08

- **Automatic re-authorise on dead OAuth refresh tokens.** When Dropbox / Google Drive / OneDrive reject a refresh token (HTTP 400 `invalid_grant` — user revoked access, password change, 7-day inactivity on Google's testing-mode apps, conditional-access policy on Microsoft tenants), the host app's `OAuthRefreshSupervisor` watches `mount.error` events for the `oauth_reauth_required:` marker that the Go drivers prefix on dead-refresh failures, opens the browser to the provider's consent screen, writes the new refresh token to the shared Keychain, and cycles the FileProvider domain so the extension respawns with fresh credentials. Google Drive and OneDrive additionally get a fresh access token written through to the mount-config plist; Dropbox doesn't carry a cached access token in plist (the `golang.org/x/oauth2` lib refreshes lazily off the keychain'd refresh token). Previously the user had to dig into mount settings and click "Sign in again"; now it's transparent. Per-mount dedupe (`inFlight: Set<String>` keyed on domainID) prevents a flurry of Finder ops opening multiple browser tabs against the same dead token.
- **Cooperative XPC-based verify + repair for EXT4 / NTFS.** Replaces the earlier preemptive-locking sketch — MAS sandbox forbids `O_EXCL` / `fcntl` over user-mounted volumes, so coordination now goes through the XPC bridge as a soft mutex. EXT4 and NTFS extensions both consult and surrender the lock around verify / repair.
- **Removed the `DiskJockeyMountHelper` privileged daemon target.** SMAppService daemons require `/Applications` and a notarised installer path the project deliberately stepped off; admin-auth flows now go through `osascript -e "do shell script ... with administrator privileges"` at the call sites that need them.
- **Consolidated per-extension I/O-stats collectors into `DiskJockeyLibrary`.** Single shared `MountStats` shape lives in the framework instead of being copy-pasted per extension; extensions import it.
- **EXT4 attribute-mask + item-cache tests** added on the Rust side via the vendored `rust-fs-ext4` submodule bump.
- **Docs refresh.** Snapshots of disk-image formats, FSKit mount architecture, IP audit, NTFS baseline, and the public roadmap landed in `docs/`.
- Submodule bumps: `rust-fs-ntfs` → `0ac1d6f` (merged main), `rust-fs-ext4` pointer advance, six new vendor crates added.

## 2026-05-03

- **I/O stats on every network driver.** FTP / SFTP / SMB now instrument the underlying `net.Conn` at dial time (FTPS counts ciphertext bytes, what the wire actually carries). WebDAV + S3 wrap their `http.Client` with the existing `CountingTransport`. Every driver implements `StatsProvider`; `networkfs_get_stats(mount_id)` returns real numbers across the board instead of zeros for five of eight drivers.
- **Native thumbnails for Google Drive and OneDrive.** GDrive uses the file metadata's `thumbnailLink` CDN URL with `=s<px>` size-rewriting; OneDrive uses `GET /items/{id}/thumbnails` to pick the right pre-rendered bucket. Neither downloads the source file. FTP / SFTP / SMB / WebDAV / S3 stay truthful (no native thumbnail API → no `Thumbnailer` impl → driver returns rc=2 → Finder falls back to a generic icon). Future client-side thumbnail generator will populate the same SQLite cache from already-downloaded file bytes, so those protocols can still get thumbnails opportunistically without lying about protocol capabilities.
- Submodule bumps for `rust-fs-ntfs` (verbose mode wired through to remote, live verbose output refactor, observability + safety contracts, bench harness + OOM fix, FUTURE_FEATURES fixes, /scan-13 docs, Tier 3 fixture dispatcher, CLI consolidation + release infra, JSONL events + tabular runner).
- Submodule bumps for `rust-fs-ext4` (close all crash-safety test gaps, sequence-advance + orphan-crash tests, Phase 5.2 finish, cross-validator infra, **ext3 RW unlock — Phase B complete**, write path Phases 1/2/3/5/6/7/8).
- `THIRD_PARTY_LICENSES` landed; README rewrite + link tidy.

## 2026-05-02

- **NTFS mount breakthrough.** `rust-fs-ntfs` volumes mount and accept writes round-tripped with the canonical Windows tooling, after switching the test contract from validator-clean to mount + write smoke. Multi-month progress ceiling on `frs.cxx` 60f broke the moment we changed what counted as "done".

## 2026-05-01

- Stats: pull transport byte counts from the network library each tick; decay live throughput when no fresh sample arrives.
- Mount: chain `mkdir` + mount under one admin auth prompt; banner File Provider connection / op errors.
- Disks: skip whole-disk preview rows so Forget sticks; offline-row Mount via DiskArbitration.
- Thumbnails: SQLite cache, cellular-data gate, enumerator pre-warm.
- Mount: per-mount `MountPolicy` with thumbnail toggles.
- **FileProvider: write support across all eight schemes.**
- **OAuth: browser sign-in for Dropbox, Google Drive, OneDrive** — refresh tokens stored in Keychain.
- UI: two-column Volume info layout; brand glyphs for FTP / SMB / Dropbox / Google Drive; sidebar-toggle in titlebar; tabler-icons vendored + sync script; SF-Symbols swap-out across LogView and clean call sites.
- Format: switch from `newfs_fskit` to `diskutil eraseDisk/eraseVolume`; wire Format buttons to FSKit `startFormat`.
- Disks: `RawDisksModel` + Unformatted Disks sidebar + format scaffolding; persist disk history to JSON in App Group; DiskArbitration session for cold-start discovery; stable identity + preview rows + cross-session persistence.
- FSKit: pure `runFsck()` with shared `FsckReport` shape; full RW write path + AppleDouble swallow; explicit verify via `startCheck`; pre-flight confirmation dialog + read-only lock indicator.
- Stats: per-mount I/O counters + sparkline UI; side-by-side counter panes.
- Logging: scope tags + per-view denylists.
- ext4: expand `BackendVolumeInfo` + FFI population with full superblock fields; set `availableBlocks` so free size renders.
- Docs: IP & licence audit landed; retired stale plan + open-issue notes.
- Spike: privileged `DiskJockeyMountHelper` target + SMAppService ping (later removed 2026-05-08).
- Submodule bumps: `rust-fs-ext4` to fsck-FFI + volume_info expansion HEAD; `rust-fs-ntfs` to mkfs HEAD, chkdsk workflow_dispatch + diagnostics, Windows compile fix, Linux ntfsfix CI gate dropped, `--create-size`; `go-networkfs` to LICENSE + classified-error HEAD; CI validation jobs across both Rust crates.

## 2026-04-22

- **Release 1.0.1** — vendor refresh + extension version alignment.
- UI: OS-flavoured icons for `ext*` / `ntfs*` attached disks.
- Build: always refresh vendor `VERSION.txt`, even on up-to-date skip.

## 2026-04-21

- UI: rename "Attached Disks" → "Local Drives", add Unmount button.
- `dev.sh`: doctor subcommand, `clean-stale-bundles`, `reset-daemons` (also bounces per-user `lsd`), `pluginkit-reload` (kill covers extension hosts).
- FileProvider: classified `networkfs_mount` errors surfaced to the UI; stop double-prefixing Finder sidebar name with "DiskJockey".
- UI: human-readable total / free size for every attached partition.
- `logtail`: seek-to-EOF on launch + O(1)-per-line parse.

## 2026-04-20

- **Direct-link architecture.** Removed the standalone backend daemon + XPC bridge in favour of linking the network library directly into the File Provider extension via cgo. End of the multi-process backend era.
- Cloud-provider OAuth registration guides (Dropbox, Google Drive, OneDrive).
- Sandbox + symlinks: user-picked folder via `NSOpenPanel` bookmark; first-run Network Drives setup pane + observable `HomeAccessService`.
- FileProvider: direct-linked FTP driver end-to-end (`libftp.a` cgo smoke through to mount/unmount toggle + live status + reconcile); classified metadata failures hard-fail; fetch into manager-temp-dir, stop stat-before-fetch.
- Logging + sidebar: route through `AppLog`, status dot, unstick "Loading"; `TaggedLogger` injected into `BlockDeviceContext` / `NTFSBlockDeviceContext`; `bsd` tag on every probe / loadResource line; newest-first ordering in per-mount + per-partition strips.
- Modernised `Makefile`; renamed `NFS_*` → `NETWORKFS_*`; deleted dead `scripts/build-godrivers.sh`; strip symbols + DWARF (-55% on-disk).
- Per-mount `TaggedLogger` end-to-end.
- Drop legacy `DiskTypeEnum` + "FTP (impl v2)" framing; colour `AttachedDiskSidebarRow` dot by `FsckStatus`.
- ext4: read dirty flag from `rust-fs-ext4`, drop Swift-side superblock peek.
- Drop unused XCFramework generation from `fs-ext4` and `fs-ntfs` scripts.
- Build: `make pins` — human-visible vendor submodule pin manifest.
- `vendor/go-networkfs` bumped to `v0.1.1`, then `dd17303`.

## 2026-04-19

- About dialog shows vendored library versions; app build time + upstream commit dates.
- Refactor: move compiled vendor output to `lib/`; wire `rust-fs-ntfs` + `go-networkfs` submodules into the `lib/` model.
- Attach NTFS image menu + parameterise mount `fsType`.
- `rust-fs-ext4` bumped to `v0.1.0` (`7071bb5`).
- `feat(fs)`: `volume.info` + per-partition log + NTFS probe label + vendor bumps.
- `feat(fsck)`: dirty-detect + auto-fsck on mount with live UI status.
- `fix(log)`: synchronous NDJSON writes + open-failure diagnostic.

## 2026-04-18

- **Vendor `rust-fs-ext4` as submodule.** End of the in-tree EXT4 source phase.
- Register `DiskJockeyEXT4` FSKit extension target; add Swift sources for FSKit ext4 mounts.
- App: Attach ext4 image menu item + `FSKitMountService`; Detach volume… menu item + FSKit detach path.
- Route `/sbin/mount` + `/sbin/umount` through admin auth prompt.
- ext4 mount runbook for DiskJockey + DiskJockeyEXT4.
- Migrate Swift bridge to `fs_ext4_*` C ABI.
- Build: rewrite for `fs_ext4` driver layout; do `lipo` + XCFramework in DiskJockey, not in `ext4-rust`; align `vendor-ext4rs` Makefile with `include/` layout.
- `fix(ext4)`: DiskJockeyEXT4 activation — app-groups + version mismatch.
- `fix(ext4)`: migrate `NSLock` to `OSAllocatedUnfairLock` for Swift 6 readiness.
- W1 empirical probe findings: signing green, Developer Mode blocks; W2 — portal capability is the real mount blocker.
- Build system update for separate `go-networkfs` driver libraries.

## 2026-04-17

- Redesign main UI around mount-centric sidebar.
- Move status bar into `AppDelegate`, add app main menu.
- Retry backend connection with backoff on startup.

## 2026-04-12

- **File Provider extension wired to XPC bridge.** First end-to-end Mac-app ↔ extension communication.
- XPC bridge as a mach-service LaunchAgent; desktop app uses LaunchAgent for backend lifecycle; XPC bridge manages Go backend lifecycle.
- Go backend auto-activates mounts on startup.
- File Provider item resolution and subdirectory navigation.
- WebDAV auto-detect HTTP vs HTTPS from port.
- Xcode build auto-compiles and signs the Go backend.
- Backend bug fixes, `MountService`, file-operation handlers.
- `fix`: proto package name mismatch — rename `proto/backend` → `proto/api`.

## 2025-06-21

- **Mounts working end-to-end.** Selecting a mount toggles a Finder sidebar volume; communication channel between the Mac app and the File Provider extension live.
- Implemented an XPC channel to the file provider; refactored the mount repository to put all calls into the backend API; restructured protobuf to two protocols (backend + fileprovider).

## 2025-06-20

- Terminology: plugins → disk types.
- Backend repositioned as a server.
- Localisation in the Mac app; missing message types added.
- `djctl` updated to work with the backend.
- Lock around the socket so multiple threads can't read or write simultaneously.
- Reconnection logic disabled (was crashing everything).
- Listing mounts and disk types in the UI as a smoke test for the protobuf code.
- Doc updates.

## 2025-06-18

- Fix race condition where the backend printed its port before it was actually listening — Mac app could connect and fail.
- Implement log-message routing into `AppLogModel` for in-app display.
- System Log doc update.

## 2025-06-16

- A working File Provider, albeit with fake data — first version since acquiring an Apple Developer account.
- Big UI upgrade; correct configuration to create File Provider resources.
- Architectural pivot: backend back to a server, frontend connects to it.
- Big refactor since removing the helper — proper models and errors, started building the backend API object.
- README polish.

## 2025-06-12

- Concluded the helper-app-mediated IPC architecture wouldn't work — superseded by the LaunchAgent XPC bridge, which itself was later superseded by the direct-link architecture (2026-04-20).
- Rewrite the app in SwiftUI (AppKit was unmanageable).
- Rewrite the backend as a client for the main application now that the helper is removed.
- Window made more app-like; mount view and quit page started.
- Project rename pass: drop old `DiskJockeyHelperLibrary` references.
- Layout fixes.

## 2025-06-09

- Update the Helper and HelperLibrary to use a TCP socket instead of a Unix socket — sandbox issues — switched to a TCP loopback connection.
- Created API objects for each "client" so components talk in a standard way.
- Created a message server to process all incoming messages.
- Helper application repositioned as the communication hub between the app, backend, and File Provider.
- File Provider no-op'd until the main TCP connection is solid.

## 2025-06-08

- This change includes the Xcode projects: main DiskJockey application, File Provider, helper application, helper library (shared between File Provider and helper application).
- Backend and CLI tool added.
- Refactor the `diskjockey-backend` to a nicer structure.
- Switch from `server.json` to a SQLite database (will be needed for managing file-sync data anyway).
- Removed magic numbers; replaced with constants.
- Project restructure: removed old files; added updated Go server backend.
- Doc updates.

## 2025-06-02

- Initial project export.
- Initial commit.
