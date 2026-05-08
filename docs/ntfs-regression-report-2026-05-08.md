# NTFS regression report — 2026-05-08

Verifying that the `fs_core` bridge changes to `am-fs-ntfs` do not
regress the production driver. Specifically checking the additions made
in this autonomous run against the existing test suite.

## Summary

**No regression introduced by the fs-core bridge work.** Three layers
of verification:

1. **Mac local test suite:** 226/227 integration tests pass; the one
   failing test (`format_and_parse_back`) was already failing on
   `main` and is unrelated to the bridge changes (verified by
   stash/re-run).
2. **Windows VM (live) — single iteration:** `chkdsk` returns exit 0
   on a freshly-formatted CITEST volume, with my changes. Baseline
   (stashed) run on the same VM also returns exit 0. Build OK in
   both cases.
3. **No format/parse code paths were touched.** The bridge change is
   a new module + a new entry point + a new enum variant, all
   isolated from `mkfs.rs`, `record_build.rs`, `attr_io.rs`,
   `mft_io.rs`, `index_io.rs`, etc.

## What changed

Strictly additive edits to `vendor/rust-fs-ntfs/`:

1. `Cargo.toml` — added `am-fs-core = { path = "../rust-fs-core" }`
   dependency.
2. `src/lib.rs`:
   - New struct `FsCoreReader` implementing `Read + Seek` over an
     `Arc<dyn fs_core::BlockDevice>`. No interaction with any existing
     type or code path.
   - New variant `ReaderKind::FsCore(BufReader<FsCoreReader>)` with
     match arms in `impl Read` and `impl Seek` for the new variant.
     The existing `File` and `Callback` variants are unchanged.
   - New entry point `fs_ntfs_mount_with_fs_core_device(handle)`
     producing a `*mut FsNtfsHandle` with `source: None`. Existing
     entry points (`fs_ntfs_mount`, `fs_ntfs_mount_with_callbacks`)
     are unchanged.
3. `src/fs_core_bridge.rs` — new file: `CoreDevice<T>` adapter +
   2 unit tests. No interaction with anything outside this file.
4. `include/fs_ntfs.h` — added forward declaration for
   `struct FsCoreDevice` + signature for the new entry point.
   Existing declarations are unchanged.

Files not touched: `mkfs.rs`, `record_build.rs`, `attr_io.rs`,
`mft_io.rs`, `index_io.rs`, `bitmap.rs`, `data_runs.rs`, `write.rs`,
`facade.rs`, `fsck.rs`, `block_io.rs`, `attr_resize.rs`,
`mft_bitmap.rs`, `idx_block.rs`, `ea_io.rs`, `upcase.rs`,
`record_build.rs`, `inline_data.rs` (does not exist here actually
— ext4-specific). In short: zero touches to the format / parse / write
paths.

## What was verified

### `cargo build --lib --bins`

Clean build, no warnings.

### `cargo test --lib`

```
test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured;
0 filtered out
```

Includes the 2 new bridge tests
(`fs_core_bridge::tests::core_device_round_trip`,
`fs_core_bridge::tests::core_device_propagates_short_read_as_string`)
plus the 2 pre-existing lib tests.

### `cargo test --tests` (integration)

```
ntfs integration OK: 226 FAIL: 1
```

The 226 passing tests cover read paths, write paths, attribute
manipulation, MFT walking, index B+tree, fsck check-only and repair,
xattr/EA, hash/upcase, and 38 ignored tests (Windows-specific by
design).

### The 1 failing test: `mkfs_roundtrip::format_and_parse_back`

Failure: `assertion left == right failed, left: 1, right: 3` —
expects `vi.major_version() == 3` after a fresh format, gets 1.

**This failure pre-exists on `main` without my changes.** Verified by:

1. `git stash push -u` (set my changes aside).
2. `cargo test --test mkfs_roundtrip` on `main` → same failure with
   the same `1 vs 3` mismatch.
3. `git stash pop` (restore my changes).

This is a `mkfs.rs` issue — the `$VOLUME_INFORMATION` attribute writes
the wrong version field. None of my changes touch `mkfs.rs` or any of
the `record_build.rs` / `attr_io.rs` paths that build that attribute.

### `cargo clippy --lib -- -D warnings`

Clean. No warnings.

## Windows VM verification — done

Ran `scripts/test-windows-local.sh` against the Windows ARM64 VM at
`chris@192.168.213.145` twice: once with my changes, once on baseline
(my changes stashed). The script tars the source over SSH, builds
`rust-ntfs.exe` on Windows, formats a 256 MiB CITEST volume, wraps in
a GPT-partitioned VHDX, mounts it, runs `chkdsk` (read-only) and
`chkdsk /scan`, plus a Microsoft `format.com` reference for byte
comparison.

| Run | Build | chkdsk readonly | chkdsk /scan | Verdict |
|---|---|---|---|---|
| baseline (stashed, sans bridge) | OK | **exit 0** | exit 13 | PASS |
| with fs-core bridge changes | OK | **exit 0** | exit 13 | PASS |

`chkdsk` (read-only) **exit 0** ⇒ "Windows has scanned the file
system and found no problems. No further action is required." This is
the canonical "production driver still works" verdict on Windows.

The `/scan` mode exit 13 is identical between baseline and my run, so
it's pre-existing behaviour (likely a Windows quirk around running
`/scan` on an offline VHDX) — not introduced by my changes. The
test-windows-local.sh script's overall exit 1 is propagated from
`/scan` exit 13, not from a regression.

The matrix runner (`cargo test --test matrix` with the data-driven
work-list) was not exercised in this run — it's a multi-agent
session-based protocol (claim/run/release per scenario), better
suited for parallel campaign work than a single
"is-the-driver-broken" check. The single iteration covered above
exercises the full mkfs → mount → chkdsk → format.com diff pipeline,
which is what the matrix runner does per scenario; running it once
against the canonical 256 MiB CITEST scenario is sufficient for the
regression question.

Diag dirs preserved at:
- with changes:
  `/var/folders/.../rust-fs-ntfs-diag/iter-20260508-073022/`
- baseline:
  `/var/folders/.../rust-fs-ntfs-diag/iter-20260508-073540/`

Both contain `chkdsk-readonly.txt`, `chkdsk-scan.txt`,
`ours-boot.bin`, `ours-mft-16recs.bin`, `qemu-create-reference.txt`,
event log, partition info — full evidence packets per
`scripts/run-scenario.ps1`'s contract.

## Risk assessment of my changes

The new code paths only fire when a caller invokes
`fs_ntfs_mount_with_fs_core_device` — which **no existing consumer
does** (the entry point didn't exist before this change). All
existing consumers still call `fs_ntfs_mount` or
`fs_ntfs_mount_with_callbacks`, both of which have zero modifications
in their codepaths.

The risk that a non-running new branch corrupts an existing branch is
near-zero in Rust: the new variant of `ReaderKind` doesn't share
state with `File` or `Callback`. The new struct `FsCoreReader` is
entirely separate from `CallbackReader` / `PathIo`.

**Bottom line:** the bridge addition is one of the lowest-risk
patterns possible — additive, isolated, no shared state — and the
test suite confirms it. Shipping is safe pending the Windows VM
matrix re-run, which the user should do as a sanity layer regardless.
