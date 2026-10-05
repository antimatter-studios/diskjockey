# What the libraries are called, and why it keeps coming back

A discussion document, not a decision record. It collects what the
constellation's library repositories, crates, imports, binaries and
Homebrew formulas are called today, what has been discussed about it, what
was proposed, and what is still open, so the question does not have to be
re-derived from old transcripts again. It is tracked by diskjockey#301.

The trigger for writing it down: on 2026-10-05 the owner remembered a
naming plan and a document describing it. The plan had been discussed on
2026-09-04 and 2026-09-05, but it had only ever been recorded in an
agent's private notes, and those notes recorded the wrong outcome as
"decided". This file is the record that should have existed then.

---

## 1. The problem

Every library is known by up to five names, and they do not agree:

- the **GitHub repository**, `antimatter-studios/rust-fs-xfs`;
- the **crates.io package** a consumer writes in `Cargo.toml`, `am-fs-xfs`;
- the **import** a consumer writes in Rust, `use fs_xfs::` (the `[lib]
  name`, independent of the package name);
- the **C ABI symbols** the Swift app calls, `fs_xfs_*`;
- the **multi-call binary** and **Homebrew formula**, `rust-fs-xfs`.

The visible annoyance is the first two: a person who finds the repository
`rust-fs-xfs` has to discover that the crate is `am-fs-xfs`, and then that
it is imported as `fs_xfs`. The `am-` prefix is a brand marker nobody
looking for an XFS reader would type into a search box.

## 2. What is there today

Read from each repository's `Cargo.toml` on `main`, 2026-10-05.

| repository | package | lib (import) | version | binaries |
|---|---|---|---|---|
| `rust-fs-core` | `am-fs-core` | `fs_core` | 0.2.23 | — |
| `rust-fs-ext4` (christhomas) | `am-fs-ext4` | `fs_ext4` | 0.7.1 | `rust-fs-ext4`, `mkfs_ext4` |
| `rust-fs-ntfs` (christhomas) | `am-fs-ntfs` | `fs_ntfs` | 0.8.0 | `rust-fs-ntfs`, `rust-ntfs` |
| `rust-fs-xfs` | `am-fs-xfs` | `fs_xfs` | 0.10.0 | `rust-fs-xfs` |
| `rust-fs-btrfs` | `am-fs-btrfs` | `fs_btrfs` | 0.8.1 | `rust-fs-btrfs` |
| `rust-fs-erofs` | `am-fs-erofs` | `fs_erofs` | 0.3.0 | `rust-fs-erofs` |
| `rust-fs-squashfs` | `am-fs-squashfs` | `fs_squashfs` | 0.3.0 | `rust-fs-squashfs` |
| `rust-img-qcow2` | `am-img-qcow2` | `qcow2` | 0.5.1 | `rust-img-qcow2` |
| `rust-img-vhd` | `am-img-vhd` | `vhd` | 0.5.1 | `rust-img-vhd` |
| `rust-img-vhdx` | `am-img-vhdx` | `vhdx` | 0.5.0 | `rust-img-vhdx` |
| `rust-img-vmdk` | `am-img-vmdk` | `vmdk` | 0.4.0 | `rust-img-vmdk` |
| `rust-partitions` | `am-partitions` | `partitions` | 0.5.0 | — |
| `rust-lzo1x` | `am-lzo1x` | `lzo1x` | 0.3.1 | `rust-lzo1x` (answers as `lzo1x`) |
| `rust-blk-probe` | `rust-blk-probe` (never published) | `blk_probe` | 0.1.2 | `blk_probe`, shipped as the tool `blk.probe` |

Not in scope, and why:

- **The Windows drivers** (`ext4-win-driver`, `xfs-win-driver`,
  `erofs-win-driver`) are applications shipped as installers, not crates.
- **`winfsp-fs-skeleton`** is a building block for those applications.
- **The two test harnesses** (`fs-windows-test-harness`,
  `fs-linux-test-harness`) are language-agnostic: they run the driver under
  test as a subprocess and read its exit status, so a Go or C driver uses
  them unchanged. A language marker in their name would be misleading.
- **`go-networkfs`** is Go, outside crates.io.
- **The C ABI symbols** (`fs_xfs_*`) stay as they are under every option
  below. C symbols live in a flat, global namespace where short
  conventional prefixes are the norm (`sqlite3_`, `curl_`, `z_`).
  `#[no_mangle]` names are explicit strings, so a crate rename does not
  touch them, and renaming them would churn 855 Swift and C call sites and
  122 exported symbols for no gain.

## 3. Facts that constrain every option

**crates.io has no rename.** There is no redirect, alias or "moved to"
field. What exists:

- a final version of the old crate whose description and README say where
  it went: text on a page someone has to visit;
- `cargo yank`, which stops new dependents from resolving a version but
  leaves existing lockfiles working and the name taken forever;
- a last version that `pub use`s the new crate, or that fails to compile
  with `compile_error!` naming the new one.

So every published `am-*` name stays on crates.io permanently, whatever is
decided. Thirteen are published. Download counts are modest and mostly CI
traffic (`am-fs-core` about 54k, `am-partitions` 9k, `am-lzo1x` 1.4k on
2026-10-05), which makes abandoning them cheap in compatibility terms.

**The import name is independent of the package name.** `use fs_xfs::`
follows `[lib] name`, so a package rename alone needs only dependency-line
edits (about 60 across the constellation and the six
`rust-bundles/dj-*-bundle` aggregators), not import edits. Changing the
import as well is a mechanical, compiler-checked edit, but a large one:
measured on 2026-09-04 at 1,814 references across about 640 files for the
`fs_*` crates.

**The Rust convention is that the `rust` marker lives on the org, not the
crate**, and that repository equals crate: `rust-lang/regex` publishes
`regex`, `tokio-rs/tokio` publishes `tokio`, `image-rs/image` publishes
`image`. A `rust-` prefix on a crate is the one prefix the ecosystem
discourages, because everything on crates.io is Rust. In this org the
marker is on the repository instead, which is defensible: the org holds
Swift (diskjockey), Go (go-networkfs) and Rust side by side, so
`rust-fs-xfs` distinguishes something in a repository list. By the same
translation as `rust-lang/regex` to `regex`, `rust-fs-xfs` would publish
`fs-xfs`.

**Availability of the bare names**, checked on crates.io 2026-10-05:

| bare name | status |
|---|---|
| `fs-ext4`, `fs-ntfs`, `fs-xfs`, `fs-btrfs`, `fs-erofs`, `fs-squashfs` | free |
| `img-qcow2`, `img-vhd`, `img-vhdx`, `img-vmdk`, `blk-probe` | free |
| `fs-core` | **taken**: a live WASM in-memory filesystem (ternbusty/monaka-fs), 0.3.1, published 2026-08-20 |
| `partitions` | **taken**: DDOtten/partitions, 0.2.4, dormant since 2018, about 496k downloads |
| `lzo1x` | **taken**: jussyDr/lzo1x, 0.2.2, GPL-2.0, so neither usable nor adoptable here |

Free alternatives seen for the three taken names: `fs-driver-core`,
`fs-common`, `fs-kit`; `disk-partitions`, `partition-table`;
`lzo1x-codec`, `lzo1x-decompress`.

## 4. How the discussion went

**2026-09-04, morning.** The question raised was `rust-fs-ntfs` (repository)
against `am-fs-ntfs` (crate). The first answer argued for keeping `am-*` as
a namespace prefix, the way `tokio-*` and `aws-sdk-*` fake the namespaces
crates.io lacks. The owner pointed out the example used for "repository
differs from crate" was backwards: `rust-lang/regex` publishes `regex`, so
`antimatter-studios/rust-fs-ntfs` should by the same rule publish without
the marker.

**2026-09-04, 11:10 — the bare-name plan.** Availability was checked: 11 of
14 bare names free, three taken (above). The plan proposed one name per
library, org carrying the identity, repository equal to crate:

```
org    antimatter-studios
repo   fs-ntfs
crate  fs-ntfs
lib    fs_ntfs          (already this today)
```

with `fs-driver-core`, `lzo1x-decompress` and `disk-partitions` for the
three taken names. For: package name finally equals import name, which is
the mismatch a consumer actually trips on. Against: `am-*` guarantees every
future crate a parallel name with no availability lottery; a future
`fs-apfs` might find its name taken and add a fourth exception. The owner's
answer: *"I don't want to change anything yet because I'm unsure what to
change to."*

**2026-09-04, 11:23.** The owner floated the opposite direction: *"perhaps
the ultimate solution is to move them to am-fs-ntfs, and don't mention rust
at all. Then at least it's consistent with the crate. But let's not do that
today."*

**2026-09-04, 14:34.** Three options were tabled:

| option | one name? | cost |
|---|---|---|
| A. `am-rust-fs-xfs` everywhere | yes | four segments; a marker on crates.io that carries no information there; 13 names abandoned |
| B. `am-fs-xfs` everywhere, repositories renamed | yes | loses the language marker in a mixed-language org; 13 names abandoned |
| C. keep the split | no | two names, each defensible where it appears; no cost |

**2026-09-04, 16:10.** The owner said *"I like it"* to: repository and crate
`am-rust-fs-xfs`, lib `am_rust_fs_xfs`, symbols `fs_xfs_*`. A cheaper
variant keeping the import as `fs_xfs` (about 62 edits instead of 1,814)
was then priced; the agent's notes recorded that variant as "decided".

**2026-09-05.** The owner referred to it as *"crate rename to am-rust-\*:
decided, never scheduled"*. Nothing was implemented, and nothing was
written into the repository.

**2026-10-05.** diskjockey#301 was filed on the assumption that the crates
should stay `am-*` and the repositories, binaries and formulas should follow
them. The owner corrected that: *"I don't want am-\*. I think it's
confusing and the wrong name. What I thought about was that rust-fs-ext4
would create a cargo package called fs-ext4."* That is the 09-04 bare-name
plan, with one difference: the repositories keep their `rust-` prefix
rather than being renamed to match.

**2026-10-05, later.** Weighing the three taken bare names again, the owner
moved to the prefix on everything: *"because rust doesn't support namespaces,
we'll have to keep the rust- prefix even if rust crates don't like it, and
then it's at least consistent. rust-fs-ext4 -> rust_fs_ext4 is verbose, but
at least consistent."* And on the prefix question generally: *"I don't like
am-rust-x, I think it's also ugly, so let's use rust-fs as a prefix in git,
the cargo crate and everything, even if rust doesn't like it."*

## 5. Where it stands

**Direction (owner, 2026-10-05):** one name per library, the repository's,
used everywhere Rust lets it be. No `am-`.

| | example |
|---|---|
| repository | `antimatter-studios/rust-fs-ext4` (unchanged) |
| crate | `rust-fs-ext4` |
| import | `rust_fs_ext4` |
| multi-call binary, Homebrew formula | `rust-fs-ext4` (unchanged) |
| per-tool names | `fs.ext4`, `mkfs.ext4` (unchanged) |

Why this one, against the convention in section 3: crates.io has no
namespaces, so every family on it fakes one with a prefix (`tokio-*`,
`aws-sdk-*`, `windows-*`). The `rust-` prefix is the one already on every
repository, so using it for the crate and the import as well gives a single
name with no exceptions. It costs verbosity and goes against the ecosystem's
dislike of `rust-` on a crate; it buys consistency and removes the
availability lottery, since every `rust-*` name the family needs is free.

**Settled:**

- **No `am-` prefix**, anywhere. The antimatter-studios brand lives in the
  GitHub org.
- **Crate equals repository**, so all three taken bare names stop mattering:
  `rust-fs-core`, `rust-lzo1x` and the partitions crate need no invented
  name. The lzo1x tool a user runs stays `lzo1x`.
- **Import equals crate**, underscored: `use rust_fs_ext4::`,
  `use rust_img_qcow2::`. This supersedes the earlier answer that the img
  crates import as `img_qcow2`.
- **No repository, binary or formula is renamed**, except as below.

**Open:**

1. **Partitions.** The owner said "disk partitions" sounds better than
   "partitions". Either the crate is `rust-partitions`, matching the
   repository with nothing renamed, or both become `rust-disk-partitions`,
   which renames the repository too.
2. **The C ABI symbols** (`fs_ext4_read_file`). Proposed: unchanged, for
   the reasons in section 2 (855 Swift and C call sites, 122 symbols, and
   short prefixes being the C norm). Not yet confirmed.
3. **What the abandoned `am-*` crates say.** The options are in section 3.
   A final version whose description and README name the new crate is the
   minimum; whether to also `yank` earlier versions, or publish a
   `pub use` shim, is a choice about how loudly to redirect.
4. **rust-blk-probe** is already named this way and was never published; if
   it merges into the partitions crate (rust-partitions#150) the question
   disappears.

## 6. What a rename touches, once decided

So the cost is visible before it is scheduled:

- each library's `Cargo.toml` `[package] name` and `[lib] name`;
- every dependency line naming an `am-*` crate: the drivers on
  `am-fs-core`, the readers on the img crates and `am-partitions`, the
  three Windows drivers, and the six `rust-bundles/dj-*-bundle`
  aggregators in this repository;
- every import (`use fs_xfs::` becomes `use rust_fs_xfs::`, `use qcow2::`
  becomes `use rust_img_qcow2::`): mechanical and compiler-checked, about
  1,814 references for the `fs_*` crates as measured on 2026-09-04, plus the
  img, partitions and lzo1x crates;
- READMEs, install examples, CHANGELOGs and `cargo add` lines;
- the publishing order: `rust-fs-core` first, then the img crates,
  partitions and lzo1x, then the filesystem crates, then the bundles;
- a final release of each `am-*` crate pointing at its successor;
- `SIBLING_PINS.txt` and `chores.yml` only if a repository is renamed
  (the partitions question).

Do it once, across the whole constellation, with one coordinated change per
repository, so no crate depends on a mixture of old and new names.
