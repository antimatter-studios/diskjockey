# Third-Party Licenses

DiskJockey is MIT-licensed (see `LICENSE`). This file enumerates the
licenses of every component statically linked into the shipped binary,
for compliance with their respective notice requirements.

## Rust crates linked into the shipped binary

Each FSKit extension links one aggregator static library from
`rust-bundles/`, which depends on the crates below. They are published
to crates.io rather than vendored, so the version linked is whatever
that bundle's `Cargo.toml` pins.

| Crate | License | Source |
|---|---|---|
| `am-fs-core` | MIT | github.com/antimatter-studios/rust-fs-core |
| `am-fs-ext4` | MIT | github.com/christhomas/rust-fs-ext4 |
| `am-fs-ntfs` | MIT OR Apache-2.0 | github.com/christhomas/rust-fs-ntfs |
| `am-fs-xfs` | MIT | github.com/antimatter-studios/rust-fs-xfs |
| `am-fs-btrfs` | MIT | github.com/antimatter-studios/rust-fs-btrfs |
| `am-fs-erofs` | MIT | github.com/antimatter-studios/rust-fs-erofs |
| `am-fs-squashfs` | MIT | github.com/antimatter-studios/rust-fs-squashfs |
| `am-img-qcow2` | MIT | github.com/antimatter-studios/rust-img-qcow2 |
| `am-img-vhd` | MIT | github.com/antimatter-studios/rust-img-vhd |
| `am-img-vhdx` | MIT | github.com/antimatter-studios/rust-img-vhdx |
| `am-img-vmdk` | MIT | github.com/antimatter-studios/rust-img-vmdk |
| `am-lzo1x` | MIT | github.com/antimatter-studios/rust-lzo1x |
| `am-partitions` | MIT | github.com/antimatter-studios/rust-partitions |

## Other direct components

| Component | License | Source |
|---|---|---|
| `go-networkfs` | MIT | github.com/christhomas/go-networkfs |
| `diskprobe` | MIT | first-party, github.com/antimatter-studios/rust-blk-probe |
| `tabler-icons` | MIT | github.com/tabler/tabler-icons |

## Transitive Rust dependencies

Every crate above resolves a closure that is entirely MIT, Apache-2.0,
BSD, Zlib, ISC, 0BSD, CC0-1.0, MIT-0 or Unicode-3.0. **No copyleft
appears in any Rust dependency tree.** Reproduce with `cargo metadata`
in each crate and read the `license` field of every package.

One entry looks like a copyleft hit and is not: `r-efi` declares
`MIT OR Apache-2.0 OR LGPL-2.1-or-later`. The licence is disjunctive, so
MIT applies; it is a dev-dependency of `tempfile` only; and it is gated
to UEFI targets, so it is never built here.

## Transitive Go dependencies (go-networkfs)

Measured at the `go-networkfs` version this repository pins
(`SIBLING_PINS.txt`: `v0.1.4`) by listing the modules every driver and
library package links, `cmd/`, `examples/` and test servers excluded:

    go list -deps -f '{{if .Module}}{{if not .Module.Main}}{{.Module.Path}}@{{.Module.Version}}{{end}}{{end}}' <packages>

**42 modules: 18 BSD, 11 Apache-2.0, 8 MIT, 1 ISC, and 1 MPL-2.0.**
Three carry no top-level `LICENSE` file, and their licences were read
from where they are stated: `kr/pretty` (`License`, MIT), `kr/text`
(`License`, MIT), `mattn/go-localereader` (README, MIT). The `go.sum`
is longer than this because it records modules the build considered
but does not link, so re-measure with the command above rather than
counting `go.sum`.

### MPL-2.0 — Mozilla Public License 2.0

Component: `github.com/hashicorp/go-uuid` v1.0.3
License: MPL-2.0
Source: github.com/hashicorp/go-uuid
Notice: This component is licensed under the Mozilla Public License,
v. 2.0. The MPL is a *file-scope* weak copyleft license — only
modifications to MPL-licensed files themselves trigger source-disclosure
obligations. Static linking of unmodified MPL files into a closed-source
binary is explicitly permitted.

It is the only copyleft-licensed component anywhere in this project, and
it enters through the **SMB** driver and nothing else (`go mod why -m`):

    go-networkfs/smb -> antimatter-studios/go-smb2-hirochachacha/v2
                     -> jcmturner/gokrb5/v8 -> hashicorp/go-uuid

**This reversed at `v0.1.4`.** Earlier revisions of this file named
`hashicorp/errwrap` and `hashicorp/go-multierror`, entering through the
FTP driver's `jlaffaye/ftp`. The FTP driver now uses
`antimatter-studios/goftp` (MIT) and links neither, and SMB moved to the
`go-smb2` fork above, which brings Kerberos and with it `go-uuid`.
Attribution here follows the pin, so re-measure when `SIBLING_PINS.txt`
moves.

The full text of the Mozilla Public License 2.0 is available at:
<https://www.mozilla.org/en-US/MPL/2.0/>

DiskJockey ships this component unmodified. Its source is the upstream
repository at the version above, which is the version recorded in
`go.sum` at the `go-networkfs` tag pinned in `SIBLING_PINS.txt`.

## Per-driver SDK licenses (network filesystem clients)

The `go-networkfs` drivers wrap protocol SDKs with these licenses:

| Driver | SDK / library | License |
|---|---|---|
| FTP | `antimatter-studios/goftp` | MIT |
| SFTP | `pkg/sftp` + `golang.org/x/crypto` | BSD-2-Clause + BSD-3-Clause |
| SMB | `antimatter-studios/go-smb2-hirochachacha/v2` (fork of `hirochachacha/go-smb2`) | BSD-2-Clause (transitive MPL-2.0 `go-uuid` via `gokrb5`, noted above) |
| Dropbox | `dropbox/dropbox-sdk-go-unofficial` | MIT |
| WebDAV | `studio-b12/gowebdav` | BSD-3-Clause |
| Google Drive | none: Go standard library over REST | BSD-3-Clause (Go) |
| Amazon S3 | `minio/minio-go/v7` | Apache-2.0 |
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
