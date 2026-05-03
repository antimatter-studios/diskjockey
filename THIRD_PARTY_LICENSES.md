# Third-Party Licenses

DiskJockey is MIT-licensed (see `LICENSE`). This file enumerates the
licenses of every component statically linked into the shipped binary,
for compliance with their respective notice requirements.

## Direct components (vendored under `vendor/`)

| Component | License | Source |
|---|---|---|
| `rust-fs-ext4` | MIT | github.com/christhomas/rust-fs-ext4 |
| `rust-fs-ntfs` | Apache-2.0 OR MIT | github.com/christhomas/rust-fs-ntfs |
| `go-networkfs` | MIT | github.com/christhomas/go-networkfs |
| `tabler-icons` | MIT | github.com/tabler/tabler-icons |

## Transitive Rust dependencies

The Rust crates (`rust-fs-ext4`, `rust-fs-ntfs`) compile against a small
set of permissively-licensed crates. License mix observed at this
release: MIT / MIT OR Apache-2.0 / Zlib / Unicode-3.0. Run
`cargo tree --license` (with `cargo-license`) inside each vendor crate
to reproduce the exact list at any commit.

## Transitive Go dependencies (go-networkfs)

The Go drivers in `go-networkfs` pull a 44-module transitive closure
across MIT / BSD-2-Clause / BSD-3-Clause / ISC / Apache-2.0 / MPL-2.0.
Two MPL-2.0 entries warrant explicit acknowledgment per their notice
requirements:

### MPL-2.0 — Mozilla Public License 2.0

Component: `github.com/hashicorp/errwrap`
License: MPL-2.0
Source: github.com/hashicorp/errwrap
Notice: This component is licensed under the Mozilla Public License,
v. 2.0. The MPL is a *file-scope* weak copyleft license — only
modifications to MPL-licensed files themselves trigger source-disclosure
obligations. Static linking of unmodified MPL files into a closed-source
binary is explicitly permitted.

Component: `github.com/hashicorp/go-multierror`
License: MPL-2.0
Source: github.com/hashicorp/go-multierror
Notice: Same MPL-2.0 terms as above. Pulled in transitively via
`github.com/hirochachacha/go-smb2`.

The full text of the Mozilla Public License 2.0 is available at:
<https://www.mozilla.org/en-US/MPL/2.0/>

DiskJockey ships these components unmodified. To obtain the source for
either, fetch the upstream repository at the version pinned in
`vendor/go-networkfs/go.sum`.

## Apache 2.0 — Swift Package Manager dependency

Component: `apple/swift-protobuf`
License: Apache-2.0
Source: github.com/apple/swift-protobuf
Notice: Linked via Swift Package Manager. Apache-2.0 only requires
license-text inclusion (this file) for redistribution.

## Per-driver SDK licenses (network filesystem clients)

The `go-networkfs` drivers wrap protocol SDKs with these licenses:

| Driver | SDK / library | License |
|---|---|---|
| FTP | `jlaffaye/ftp` | ISC |
| SFTP | `pkg/sftp` + `golang.org/x/crypto` | BSD-2-Clause + BSD-3-Clause |
| SMB | `hirochachacha/go-smb2` | BSD-2-Clause (transitive MPL noted above) |
| Dropbox | `dropbox/dropbox-sdk-go-unofficial` | MIT |
| WebDAV | `studio-b12/gowebdav` | BSD-3-Clause |
| Google Drive | `google.golang.org/api` (raw REST) | BSD-3-Clause |
| Amazon S3 | `aws/aws-sdk-go-v2` | Apache-2.0 |
| OneDrive | Microsoft Graph (raw REST) | BSD-3-Clause client |

## Spec sources cited in code

The pure-Rust filesystem drivers were written from public on-disk
format specifications, **not** derived from any GPL-licensed prior-art
codebase. Spec sources cited in source comments:

- ext4 on-disk format — kernel.org/doc/html/latest/filesystems/ext4/
- NTFS on-disk format — Microsoft public specifications + reverse-
  engineered structural references; cross-validated against Microsoft's
  own `chkdsk` for correctness
- Brian Carrier, *File System Forensic Analysis* (Addison-Wesley, 2005)
  — chapter 14 (ext) and chapter 12 (NTFS)

## Updating this file

When a vendor submodule pointer is bumped, the corresponding entry
above should be reviewed for license-mix changes. New MPL-or-restrictive
deps appearing in `go-networkfs` `go.sum` should be added to the
"Transitive Go dependencies" section before release.
