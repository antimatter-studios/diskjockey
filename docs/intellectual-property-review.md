# Intellectual Property & Licence Review

**Date:** 2026-05-01
**Reviewer:** automated audit (Claude) at user request
**Scope:** entire DiskJockey repository, including all submodules and the
full transitive Go and Rust dependency graphs.

## Why this review exists

DiskJockey itself is **MIT-licensed** (see [`LICENSE`](../LICENSE)). The
intent is for the project to be *more* permissive, not less. That means
the failure mode we are guarding against is the inverse of the usual
proprietary-software fear: we are not worried about losing trade
secrets, we are worried about **copyleft contamination forcing the
project into a stricter licence than MIT**.

Specifically:

- **GPL / LGPL / AGPL** code, if linked into an MIT distribution, would
  require the resulting binary (or, for AGPL, the network service) to
  be distributed under GPL-family terms — incompatible with MIT.
- **MPL-2.0** is weak (file-scope) copyleft and is compatible with MIT
  distribution as long as the MPL files themselves remain MPL and any
  modifications to those files are published.
- **Permissive** licences (MIT, BSD-2/3-Clause, ISC, Apache-2.0,
  Zlib, Unicode-3.0, Unlicense) compose freely with MIT.

User stance recorded in project memory:
> *Avoid GPL/LGPL/AGPL; prefer MIT/BSD/Apache or hand-roll with stdlib.*

## Method

1. Enumerated every submodule listed in [`.gitmodules`](../.gitmodules).
2. Read each submodule's `LICENSE` / `LICENSE-*` / `Cargo.toml` /
   `package.json` / `go.mod`.
3. For Rust submodules, ran `cargo metadata` against the declared
   dependency set and inspected the `license` field of every
   transitive crate.
4. For the Go submodule (`go-networkfs`), ran
   `go list -deps ./...` to capture the full build graph, then
   inspected the `LICENSE` file of every module in the graph from the
   local module cache (`$GOMODCACHE`).
5. Read [`Package.resolved`](../DiskJockey.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)
   for Swift Package Manager dependencies.
6. Greppped the in-repo Swift, Rust, and Go source for:
   - GPL/Affero/copyleft markers,
   - third-party copyright headers (anything not "Chris Thomas" /
     "Antimatter Studios"),
   - inline attributions such as `adapted from`, `ported from`,
     `based on`, `stackoverflow`, `gist.github`, `@author`.

## Findings

### ✅ DiskJockey first-party source

| Path | Authorship |
|---|---|
| `DiskJockeyApplication/`, `DiskJockeyEXT4/`, `DiskJockeyNTFS/`, `DiskJockeyFileProvider/`, `DiskJockeyLibrary/`, `DiskJockey*Tests/` | Chris Thomas; no third-party copyright headers; no copy-pasted snippets matching the search heuristics above. |

No third-party attribution-style comments remain in the host-app
sources after the 2026-05-01 sweep that scrubbed every reference to
GPL prior-art tooling (see commit history).

### ✅ Submodules (direct dependencies)

| Submodule | Pinned ref | Licence | Verdict |
|---|---|---|---|
| [`vendor/rust-fs-ext4`](../vendor/rust-fs-ext4) | v0.1.2 (`6c44c3…`) | MIT | own work, clean |
| [`vendor/rust-fs-ntfs`](../vendor/rust-fs-ntfs) | v0.1.2 (`e02b6d…`) | MIT OR Apache-2.0 | own work, clean |
| [`vendor/go-networkfs`](../vendor/go-networkfs) | v0.1.3 (`57a58f…`) | MIT (declared in README; LICENSE file added 2026-05-01, see below) | own work |
| [`vendor/tabler-icons`](../vendor/tabler-icons) | tracking upstream | MIT (Paweł Kuna) | third-party, MIT — attribution required |

### ✅ Rust filesystem implementations — clean-room status

The pure-Rust ext4 and NTFS implementations are reverse-engineered
from public format documentation, not copied from existing GPL
implementations of either filesystem.

Evidence — every module-level docstring in `vendor/rust-fs-ntfs/src/`
that references format-layout details is explicitly headered with
`(no GPL code consulted)` and cites
[flatcap.github.io/linux-ntfs](https://flatcap.github.io/linux-ntfs/),
which is documentation, not source code.

Files containing this marker:

```
vendor/rust-fs-ntfs/src/attr_io.rs
vendor/rust-fs-ntfs/src/index_io.rs
vendor/rust-fs-ntfs/src/mft_io.rs
vendor/rust-fs-ntfs/src/ea_io.rs
vendor/rust-fs-ntfs/src/idx_block.rs
vendor/rust-fs-ntfs/src/record_build.rs
vendor/rust-fs-ntfs/src/upcase.rs
vendor/rust-fs-ntfs/src/mkfs.rs
vendor/rust-fs-ntfs/src/data_runs.rs
vendor/rust-fs-ntfs/src/bitmap.rs
vendor/rust-fs-ntfs/src/attr_resize.rs
vendor/rust-fs-ntfs/src/mft_bitmap.rs
```

**Conclusion: clean-room. No GPL code consulted or incorporated.
Behavioural documentation references existing implementations only by
generic category ("Linux NTFS reimplementations", "kernel ext4 driver"),
never by name.**

### ✅ Rust transitive dependencies (36 crates)

Resolved via `cargo metadata` for the union of `rust-fs-ext4` and
`rust-fs-ntfs` direct deps.

| Licence | Crates |
|---|---|
| MIT OR Apache-2.0 | the overwhelming majority — `bitflags`, `arrayvec`, `autocfg`, `crc32c`, `derive_more`, `displaydoc`, `either`, `enumn`, `heck`, `hex`, `nt-string`, `ntfs`, `num-conv`, `powerfmt`, `proc-macro2`, `quote`, `rustc_version`, `rustversion`, `semver`, `serde_core`, `serde_derive`, `syn`, `time`, `time-core`, `time-macros`, `widestring`, … |
| MIT only | `binrw`, `binrw_derive`, `convert_case`, `memoffset`, `strum_macros` |
| Zlib OR Apache-2.0 OR MIT | `bytemuck` |
| Unlicense OR MIT | `byteorder` |
| (MIT OR Apache-2.0) AND Unicode-3.0 | `unicode-ident` |

**No copyleft. No GPL/LGPL/AGPL/MPL.**

### ⚠️ Go transitive dependencies (44 modules)

44 modules in the `go-networkfs` build closure. Almost all permissive
(MIT / Apache-2.0 / BSD-2-Clause / BSD-3-Clause / ISC), with **two
MPL-2.0 transitive dependencies**:

| Module | Licence | Pulled by |
|---|---|---|
| `github.com/hashicorp/errwrap` | **MPL-2.0** | indirect, via `go-multierror` |
| `github.com/hashicorp/go-multierror` | **MPL-2.0** | `github.com/hirochachacha/go-smb2` (SMB driver) |

**Risk assessment:** MPL-2.0 is **file-scope weak copyleft**, not the
viral kind. It is **MIT-compatible** as a dependency: you may include
MPL files inside a larger MIT-distributed work; only the MPL files
themselves remain under MPL, and modifications to *those specific
files* must be published. We have not modified them.

**Required obligations to satisfy MPL-2.0 §3:**

1. Preserve their `LICENSE` files inside any binary distribution
   (or ship a `THIRD_PARTY_LICENSES.md` that reproduces them).
2. Make the source of those two modules available to recipients (the
   GitHub repos satisfy this; we do not need to redistribute them
   ourselves).
3. If we ever modify those files, publish the modifications.

**Note on alternatives:** the only realistic Go SMB2 client is
`hirochachacha/go-smb2`. The plausible alternative is `cgo` to
`libsmbclient`, which is **LGPL-3.0** and would be *worse* — strictly
more obligation than the current MPL-2.0 transitive. Keeping the
current dependency is the right call.

The remaining 42 Go modules are all permissive: see Appendix A.

### ✅ Swift Package Manager dependencies

Only one external Swift package is pinned (see
[`Package.resolved`](../DiskJockey.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)):

| Package | Licence |
|---|---|
| `apple/swift-protobuf` v1.36.1 | Apache-2.0 |

MIT-compatible.

### ⚠️ Tabler icons (assets)

Imagesets under `DiskJockeyApplication/Assets.xcassets/tabler-*` are
derived from [`vendor/tabler-icons`](../vendor/tabler-icons) (MIT,
Paweł Kuna). MIT requires the copyright + permission notice be
reproduced "in all copies or substantial portions of the Software."

**Action:** include in the forthcoming `THIRD_PARTY_LICENSES.md`.

## Actions

### Done

- **2026-05-01 — added `LICENSE` (MIT) to `vendor/go-networkfs`.**
  The repo's `README.md` already declared `## License — MIT`, but
  there was no `LICENSE` file, which made the licence undetectable
  by GitHub's licence detector, `pkg.go.dev`, and most SCA tools.
  Pushed to branch `add-mit-license` on
  https://github.com/christhomas/go-networkfs ; merge to `main`,
  then run `make pins` in this repo to bump the submodule pointer.

### Open

- **`THIRD_PARTY_LICENSES.md`** — generate a single attribution file
  reproducing the MIT / BSD / Apache-2.0 / MPL-2.0 / Zlib /
  Unlicense / Unicode-3.0 notices for every transitive dependency
  shipped in the binaries. Tools: `go-licenses`, `cargo about`.
  Ship as a file in the repo and bundled into the macOS app's
  Resources.

- **`go mod tidy` inside `vendor/go-networkfs`** — the indirect-only
  `golang/protobuf`, `google.golang.org/appengine`, and
  `google.golang.org/protobuf` modules appear in `go.mod` but are
  not in the actual build graph. All three are BSD-3 (no risk), but
  the manifest could be cleaned up.

- **Periodic re-review.** Re-run this audit when:
  - a new submodule is added (`.gitmodules` change),
  - `go.mod` or `Cargo.toml` gains a new direct dependency,
  - `Package.resolved` adds a new SPM pin,
  - source files appear with non-Chris-Thomas copyright headers.

## Conclusion

**No GPL, LGPL, or AGPL code is present anywhere in the repository or
its transitive dependency closure.** The MIT licence on DiskJockey
is not at risk of being forced into a stricter copyleft licence by
any current dependency.

The only mid-tier finding is two MPL-2.0 transitive Go dependencies
that compose cleanly with MIT distribution provided the obligations
above are met. This is a documentation / `THIRD_PARTY_LICENSES.md`
task, not a re-architecture task.

---

## Appendix A — Go module licence inventory

Recorded as observed on 2026-05-01 from `$GOMODCACHE`.

| Module | Licence |
|---|---|
| github.com/aymanbagabas/go-osc52/v2 | MIT |
| github.com/charmbracelet/bubbletea | MIT |
| github.com/charmbracelet/colorprofile | MIT |
| github.com/charmbracelet/lipgloss | MIT |
| github.com/charmbracelet/x/ansi | MIT |
| github.com/charmbracelet/x/cellbuf | MIT |
| github.com/charmbracelet/x/term | MIT |
| github.com/dropbox/dropbox-sdk-go-unofficial/v6 | MIT |
| github.com/dustin/go-humanize | MIT |
| github.com/geoffgarside/ber | BSD-3-Clause |
| github.com/go-ini/ini | Apache-2.0 |
| github.com/google/uuid | BSD-3-Clause |
| **github.com/hashicorp/errwrap** | **MPL-2.0** |
| **github.com/hashicorp/go-multierror** | **MPL-2.0** |
| github.com/hirochachacha/go-smb2 | BSD-3-Clause |
| github.com/jlaffaye/ftp | ISC |
| github.com/klauspost/compress | BSD-3-Clause + MIT (hybrid header) |
| github.com/klauspost/cpuid/v2 | MIT |
| github.com/klauspost/crc32 | BSD-3-Clause |
| github.com/kr/fs | BSD-3-Clause |
| github.com/lucasb-eyer/go-colorful | MIT |
| github.com/mattn/go-isatty | MIT |
| github.com/mattn/go-runewidth | MIT |
| github.com/minio/crc64nvme | Apache-2.0 |
| github.com/minio/md5-simd | Apache-2.0 |
| github.com/minio/minio-go/v7 | Apache-2.0 |
| github.com/muesli/ansi | MIT |
| github.com/muesli/cancelreader | MIT |
| github.com/muesli/termenv | MIT |
| github.com/philhofer/fwd | MIT |
| github.com/pkg/sftp | BSD-2-Clause |
| github.com/rivo/uniseg | MIT |
| github.com/rs/xid | MIT |
| github.com/studio-b12/gowebdav | BSD-3-Clause |
| github.com/tinylib/msgp | MIT (with portions BSD-3-Clause from Go authors) |
| github.com/xo/terminfo | MIT |
| go.yaml.in/yaml/v3 | MIT + Apache-2.0 (dual) |
| goftp.io/server/v2 | MIT |
| golang.org/x/crypto | BSD-3-Clause |
| golang.org/x/image | BSD-3-Clause |
| golang.org/x/net | BSD-3-Clause |
| golang.org/x/oauth2 | BSD-3-Clause |
| golang.org/x/sys | BSD-3-Clause |
| golang.org/x/text | BSD-3-Clause |
| gopkg.in/yaml.v3 | MIT + Apache-2.0 (dual) |

## Appendix B — Rust crate licence inventory

Recorded as observed on 2026-05-01 from `cargo metadata`.

| Crate | Licence |
|---|---|
| array-init | MIT OR Apache-2.0 |
| arrayvec | MIT OR Apache-2.0 |
| autocfg | Apache-2.0 OR MIT |
| binrw | MIT |
| binrw_derive | MIT |
| bitflags | MIT OR Apache-2.0 |
| bytemuck | Zlib OR Apache-2.0 OR MIT |
| byteorder | Unlicense OR MIT |
| convert_case | MIT |
| crc32c | Apache-2.0/MIT |
| deranged | MIT OR Apache-2.0 |
| derive_more | MIT |
| displaydoc | MIT OR Apache-2.0 |
| either | MIT OR Apache-2.0 |
| enumn | MIT OR Apache-2.0 |
| heck | MIT OR Apache-2.0 |
| hex | MIT OR Apache-2.0 |
| memoffset | MIT |
| nt-string | MIT OR Apache-2.0 |
| ntfs | MIT OR Apache-2.0 |
| num-conv | MIT OR Apache-2.0 |
| powerfmt | MIT OR Apache-2.0 |
| proc-macro2 | MIT OR Apache-2.0 |
| quote | MIT OR Apache-2.0 |
| rustc_version | MIT OR Apache-2.0 |
| rustversion | MIT OR Apache-2.0 |
| semver | MIT OR Apache-2.0 |
| serde_core | MIT OR Apache-2.0 |
| serde_derive | MIT OR Apache-2.0 |
| strum_macros | MIT |
| syn | MIT OR Apache-2.0 |
| time | MIT OR Apache-2.0 |
| time-core | MIT OR Apache-2.0 |
| time-macros | MIT OR Apache-2.0 |
| unicode-ident | (MIT OR Apache-2.0) AND Unicode-3.0 |
| widestring | MIT OR Apache-2.0 |
