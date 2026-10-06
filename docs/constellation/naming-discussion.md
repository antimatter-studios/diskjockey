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

**2026-10-05, last.** The owner then proposed dropping the prefix at the
source level only: *"repo rust-fs-ext4, crate rust-fs-ext4, package
fs_ext4 ... all the external packages are all consistent, and we chop off
the rust-x prefix when it comes to the source code level. We would only have
a problem if you tried to use the multiple overlapping crates."*

Asked whether the scheme conflicts with anything, the review found no
blocker: the three import-name clashes it keeps (`fs_core`, `partitions`,
`lzo1x`) exist today and cost one rename line in the rare crate that lists
both namesakes directly, and the four the img crates have today (`qcow2`,
`vhd`, `vhdx`, `vmdk` are all taken on crates.io) go away. The owner: *"if
we migrate to the same naming scheme, eventually we'll end up with a better,
more consistent setup rather than everything using different conventions."*

## 5. Where it stands

**Decided (owner, 2026-10-05):** every name a person meets outside the
source is the repository's; inside the source, the `rust-` prefix is dropped.
No `am-`. The migration is tracked by diskjockey#301 and is not yet
scheduled.

| | example |
|---|---|
| repository | `antimatter-studios/rust-fs-ext4` (unchanged) |
| crate on crates.io | `rust-fs-ext4` |
| multi-call binary, Homebrew formula | `rust-fs-ext4` (unchanged) |
| per-tool names | `fs.ext4`, `mkfs.ext4` (unchanged) |
| import (`[lib] name`) | `fs_ext4` (unchanged) |
| C ABI symbols | `fs_ext4_*` (unchanged, and now the same stem as the import) |

Applied to the family:

| repository = crate | import |
|---|---|
| `rust-fs-core` | `fs_core` |
| `rust-fs-ext4`, `-ntfs`, `-xfs`, `-btrfs`, `-erofs`, `-squashfs` | `fs_ext4` and so on |
| `rust-img-qcow2`, `-vhd`, `-vhdx`, `-vmdk` | `img_qcow2` and so on (today `qcow2`) |
| `rust-disk-partitions` (renamed from `rust-partitions`) | `disk_partitions` |
| `rust-lzo1x` | `lzo1x` |
| `rust-blk-probe` | `blk_probe` |

Why this one:

- **One public name.** Whoever finds the library on GitHub, crates.io,
  Homebrew or `$PATH` meets the same name and types the same name. crates.io
  has no namespaces, so some prefix is unavoidable; `rust-` is the one every
  repository already carries, and every `rust-*` name the family needs was
  free on 2026-10-05.
- **The source stays short and unchanged.** Every `fs_*` crate is imported
  this way already, so the 1,814 import edits a full rename would cost
  disappear; only the img and partitions crates' imports move: `qcow2` to
  `img_qcow2`, which is the prefix rule applied to them, and `partitions`
  to `disk_partitions`, which follows the crate's new name.
- **Precedent.** A package name that differs from the import is ordinary
  Rust: `rust-ini` is imported as `ini`, and this family already ships
  `am-fs-ext4` imported as `fs_ext4`. A README states the import at the
  top so nobody has to guess.
- **The cost of an import-name clash is small.** Two crates with the same
  import name only collide when one crate lists both as direct
  dependencies — ours `rust-fs-core` and the unrelated `fs-core` both
  import as `fs_core`, as could `partitions` and `lzo1x`. Cargo resolves that
  with one `name = { package = "..." }` line where the dependency is
  declared; two such crates deeper in the dependency graph never meet.

**Settled:**

- **No `am-` prefix**, anywhere. The antimatter-studios brand lives in the
  GitHub org.
- **Crate equals repository**, so the three taken bare names (`fs-core`,
  `partitions`, `lzo1x`) need no invented replacement.
- **The import is the repository name without `rust-`**, underscored. This
  supersedes the same day's "`rust_fs_ext4` everywhere" answer.
- **C symbols are unchanged**, and match the import.
- **No repository, binary or formula is renamed**, except partitions:
- **Partitions is `rust-disk-partitions`** (owner, 2026-10-06): repository,
  crate, and import `disk_partitions`. The repository is renamed from
  `rust-partitions` (GitHub redirects the old name), and its importers move
  from `use partitions::` to `use disk_partitions::`.

**Known clashes the scheme keeps** (from the review above): `fs_core`
and `lzo1x` are also the import names of unrelated crates (`partitions`
was a third, until the partitions crate became `disk_partitions`).
Only a crate that depends on both namesakes directly has to rename one
(`name = { package = "..." }`); `lzo1x` is the likeliest, since the other
one is GPL and a reader typing `use lzo1x::` could reach either.

**Tidy at migration time:** `rust-fs-ntfs` also builds a `rust-ntfs` binary,
and `rust-fs-ext4` and `rust-fs-ntfs` build `mkfs_ext4` and `mkfs_ntfs`
beside the dotted tool names; `cargo install` puts all of them on PATH.

- **The CLI layer is unchanged**, as `docs/cli-tooling-design.md` set it:
  one cargo target per repository, the multi-call binary named for the
  repository, `<verb>.<fs>` names as relative symlinks the release makes,
  the Homebrew formula named for the repository. The stray extra targets
  (`mkfs_ext4` in rust-fs-ext4, `rust-ntfs` and `mkfs_ntfs` in
  rust-fs-ntfs) break the one-target rule and are removed.
- **The `am-*` crates get one final release each** (owner, 2026-10-06):
  the same code, a description saying the crate is renamed and receives
  no further versions, and a README naming and linking the `rust-*`
  crate with the one-line `Cargo.toml` change. Nothing is yanked and no
  `pub use` shim is published; projects switch when they choose to. A
  shim can still be published later if an outside user turns up.
- **The migration is now** (owner, 2026-10-06): before more people depend
  on the `am-*` names.

**Open:**

1. **rust-blk-probe** is already named this way and was never published; if
   it merges into the partitions crate (rust-partitions#150, now rust-disk-partitions) the question
   disappears.

## 6. What a rename touches, once decided

So the cost is visible before it is scheduled:

- each library's `Cargo.toml` `[package] name` and `[lib] name`;
- every dependency line naming an `am-*` crate: the drivers on
  `am-fs-core`, the readers on the img crates and `am-partitions`, the
  three Windows drivers, and the six `rust-bundles/dj-*-bundle`
  aggregators in this repository;
- the img crates' imports (`use qcow2::` becomes `use img_qcow2::`),
  mechanical and compiler-checked; no other import changes;
- READMEs, install examples, CHANGELOGs and `cargo add` lines;
- the publishing order: `rust-fs-core` first, then the img crates,
  partitions and lzo1x, then the filesystem crates, then the bundles;
- a final release of each `am-*` crate pointing at its successor;
- the `rust-partitions` repository rename, and with it every
  `SIBLING_PINS.txt`, `chores.yml` URL, sibling path and README link that
  names it; `use partitions::` becomes `use disk_partitions::` in its
  importers.

Do it once, across the whole constellation, with one coordinated change per
repository, so no crate depends on a mixture of old and new names.
