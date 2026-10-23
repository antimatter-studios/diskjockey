# CLI capability execution contract

`scripts/cli-capability-matrix.sh --matrix FILE --images DIR` executes a TSV
against prepared images and tools on PATH. Install `jq` first. The entire
matrix is checked for missing inputs before any operation runs. Output goes
through this repository's `quiet-run.sh` to
`tmp/logs/cli-capability-matrix.log`; `--verbose` also streams it.

The first line is exactly these five tab-separated fields (`\t` below
denotes an actual tab):

```text
tool	fixture	exit	stdin	argv...
```

Each subsequent row contains a tool name (`fs.ext4`, for example), an image
filename, the expected exit (`0` supported or `3` refused), an stdin filename
or `-` for empty input, and one or more literal argument fields. Arguments
after the tool's TARGET each occupy their own tab-separated field. Spaces,
quotes and shell syntax inside a field remain literal; there is no shell
evaluation. Blank lines and lines starting with `#` are ignored. Empty
fields, carriage returns and paths outside the image directory are refused.
Fixtures and stdin files use simple filenames starting with a letter or
digit, followed by letters, digits, dots, underscores or hyphens.

For example, with tabs between columns:

```text
tool	fixture	exit	stdin	argv...
fs.ext4	ext4.img	0	-	stat	/data.bin
fs.erofs	erofs.img	3	-	rm	/data.bin
fs.ext4	ext4.img	0	payload.bin	write	--at	1	/data.bin
```

Every row receives a fresh writable image copy. A usage error (`2`) always
fails, as does any other exit that disagrees with the row. Exit `3` also
requires empty stdout, exactly one JSON error object on stderr with a
nonempty `error` string and numeric `code: 3`, and an image byte-identical
to the copy taken before invocation. The supplied source fixture is never
passed to the driver. The executor counts every row and refuses an empty
matrix or a run that stops short.

Add `--install` to run with all seven filesystem CLIs from the exact tags in
`SIBLING_PINS.txt`. This requires GitHub CLI with `gh attestation verify`
and `--source-ref` support, plus `tar` and a SHA-256 tool (`sha256sum` or
`shasum`). Supported hosts are darwin-arm64 and linux-x86_64. The installer
downloads each tag's platform archive and verifies its signed digest,
repository, shared `rust-fs-core/.github/workflows/release-cli.yml` signer,
and `refs/tags/<tag>` source ref before extraction. It never executes a
driver during installation. Missing or duplicate pins, unavailable assets,
failed attestations and missing executable binaries fail the run.

All seven releases must pass before any matrix operation runs. Installed
mode permits only those seven tool names and uses a private installation,
with no fallback to an existing driver on PATH. Only the `fs.*` commands
are exposed, so release-provided `mkfs.*` commands cannot shadow independent
builders. Exact tags, asset names, SHA-256 digests, signers and source refs
are retained in the capability log. The private installation is removed
on exit. Prepared-tool mode remains available without `--install`.

For a persistent installation, use
`bash scripts/install-cli-capabilities.sh --dest NEW_DIR`; it refuses an
existing destination and writes `NEW_DIR/releases.tsv` plus `NEW_DIR/bin`.
`--pins FILE` selects an alternate pins file for installer guards.

## The ext4 seed

`bash scripts/ext4-capability-fixture.sh --dest NEW_DIR` builds `ext4.img`
and `payload.bin` with e2fsprogs only: `mke2fs -d` copies a prepared tree
and `debugfs` sets the extended attribute. It then reads the seed back with
`e2fsck -fn` and `debugfs`, never with this constellation's readers, and
refuses a seed whose names, bytes, hard link, symlink target, empty
directory or xattr disagree. `--check DIR` runs the executor over three rows
that each remove `/data.bin` through `debugfs`, so a reused copy or a write
to the source fixture fails the run. The Shell scripts job runs both modes
on Ubuntu. A missing `mke2fs`, `debugfs` or `e2fsck` fails naming e2fsprogs
before anything is created; nothing is skipped.

| path | operand for |
|---|---|
| `/data.bin` (8 KiB, `user.capability=seed`) | stat, write --at, truncate, rm, xattr |
| `/dir/file.txt` | recursive ls, rm of a child, a nonempty rmdir refusal |
| `/empty` | rmdir, mkdir --parents below it |
| `/link-target.txt`, `/hardlink.txt` | hard links (link count 2) |
| `/symlink` -> `data.bin` | symbolic links |
| `/mv-src.txt`, `/replace-dst.txt` | mv, and mv onto an existing destination |
| `payload.bin` (4 KiB) | stdin for write rows |

Format limits: ext4 has no named data streams, so stream verbs have no
operand and a correct driver refuses them (exit 3). The seed is 32 MiB with
4 KiB blocks and 256-byte inodes, so the xattr is stored in the inode.

## The ntfs seed

`bash scripts/ntfs-capability-fixture.sh --dest NEW_DIR` builds `ntfs.img`
and `payload.bin` with ntfs-3g only: `mkntfs` formats the image and an
ntfs-3g FUSE mount (CI, Ubuntu, as root) copies a prepared tree in, makes
the hard link and the symlink, and writes the named stream with `setfattr`.
It then reads the unmounted seed back with `ntfsls`, `ntfscat` and
`ntfsinfo`, never with this constellation's readers, and refuses a seed
whose names, bytes, hard link, symlink target, empty directory or stream
disagree. `--check DIR` runs the executor over three rows that each
overwrite `/data.bin` through `ntfscp`, failing if it is already
overwritten, so a reused copy or a write to the source fixture fails the
run. The Shell scripts job installs ntfs-3g and attr and runs both modes.
A missing `mkntfs`, `ntfs-3g`, `ntfscp`, `ntfscat`, `ntfsinfo`, `ntfsls` or
`setfattr` fails naming its package before anything is created; nothing is
skipped. These GPL tools are run as separate programs, as oracles; nothing
links or copies them.

| path | operand for |
|---|---|
| `/data.bin` (8 KiB) | stat, write --at, truncate, rm |
| `/data.bin:capability` (`seed`) | named-stream verbs, and xattr verbs as `user.capability` |
| `/dir/file.txt` | recursive ls, rm of a child, a nonempty rmdir refusal |
| `/empty` | rmdir, mkdir --parents below it |
| `/link-target.txt`, `/hardlink.txt` | hard links (two names on one MFT record) |
| `/symlink` -> `data.bin` | symbolic links |
| `/mv-src.txt`, `/replace-dst.txt` | mv, and mv onto an existing destination |
| `payload.bin` (4 KiB) | stdin for write rows |

NTFS format limits: NTFS has no POSIX xattrs. ntfs-3g presents named data
streams as `user.*` xattrs, so the one stream is the operand for both verb
families, and other xattr namespaces have no operand. NTFS extended
attributes (`$EA`) are not in the seed. The symlink is whatever ntfs-3g
writes (an Interix file or a reparse point); the checker accepts either
because both name `data.bin`. The seed is 32 MiB with mkntfs's default
4 KiB clusters and zeroed timestamps.

## The xfs seed

`bash scripts/xfs-capability-fixture.sh --dest NEW_DIR` builds `xfs.img`
and `payload.bin` with xfsprogs and the kernel only: `mkfs.xfs -p` formats
the image and populates it from a protofile, and a kernel loop mount (CI,
Ubuntu, as root) adds the hard link and writes the xattr with `setfattr`,
the two things a protofile cannot express. It then checks the unmounted
seed with `xfs_repair -n` and reads it with `xfs_db`, and reads it again
through a read-only kernel mount, never with this constellation's readers.
It refuses a seed whose names, bytes, hard link, symlink target, empty
directory or xattr disagree. `--check DIR` runs the executor over three
rows that each relabel the image with `xfs_db -x`, failing if the label has
already changed, so a reused copy or a write to the source fixture fails
the run. The Shell scripts job installs xfsprogs and attr and runs both
modes. A missing `mkfs.xfs`, `xfs_db`, `xfs_repair`, `setfattr`, `getfattr`,
`mount` or `umount` fails naming its package before anything is created;
nothing is skipped. These GPL tools are run as separate programs, as
oracles; nothing links or copies them.

| path | operand for |
|---|---|
| `/data.bin` (8 KiB, `user.capability=seed`) | stat, write --at, truncate, rm, xattr |
| `/dir/file.txt` | recursive ls, rm of a child, a nonempty rmdir refusal |
| `/empty` | rmdir, mkdir --parents below it |
| `/link-target.txt`, `/hardlink.txt` | hard links (one inode, link count 2) |
| `/symlink` -> `data.bin` | symbolic links |
| `/mv-src.txt`, `/replace-dst.txt` | mv, and mv onto an existing destination |
| `payload.bin` (4 KiB) | stdin for write rows |

XFS format limits: XFS has no named data streams, so stream verbs have no
operand and a correct driver refuses them (exit 3). The one xattr is in the
`user` namespace and short enough to live in the inode's attribute fork.
mkfs.xfs refuses a filesystem below 300 MiB, so the seed is a sparse
320 MiB file with mkfs.xfs's defaults (v5, CRCs on, 4 KiB blocks). The
protofile owns everything as uid 0, gid 0.

## The btrfs seed

`bash scripts/btrfs-capability-fixture.sh --dest NEW_DIR` builds `btrfs.img`
and `payload.bin` with btrfs-progs and the kernel only. `mkfs.btrfs
--rootdir` formats the image and populates it from a staged tree, symbolic
link included. A kernel loop mount (CI, Ubuntu, as root) then adds the hard
link and writes the xattr with `setfattr`. It checks the unmounted seed
with `btrfs check --readonly` and finds every name and the xattr's name in
`btrfs inspect-internal dump-tree -t 5`. It reads the seed again through a
read-only kernel mount, never with this constellation's readers, and refuses
a seed whose names, bytes, hard link, symlink target, empty directory or
xattr disagree. `--check DIR` runs the executor over three rows. Each row
relabels the image with `btrfs filesystem label` and fails if the label has
already changed, so a reused copy or a write to the source fixture fails the
run. The Shell scripts job installs btrfs-progs and attr and runs both
modes. A missing `mkfs.btrfs`, `btrfs`, `setfattr`, `getfattr`, `mount` or
`umount` fails naming its package before anything is created; nothing is
skipped. These GPL tools are run as separate programs, as oracles; nothing
links or copies them.

| path | operand for |
|---|---|
| `/data.bin` (8 KiB, `user.capability=seed`) | stat, write --at, truncate, rm, xattr |
| `/dir/file.txt` | recursive ls, rm of a child, a nonempty rmdir refusal |
| `/empty` | rmdir, mkdir --parents below it |
| `/link-target.txt`, `/hardlink.txt` | hard links (one inode, link count 2) |
| `/symlink` -> `data.bin` | symbolic links |
| `/mv-src.txt`, `/replace-dst.txt` | mv, and mv onto an existing destination |
| `payload.bin` (4 KiB) | stdin for write rows |

Btrfs format limits: Btrfs has no named data streams, so stream verbs have
no operand and a correct driver refuses them (exit 3). The one xattr is in
the `user` namespace. Everything is in the top-level subvolume (id 5); the
seed has no other subvolume or snapshot. The seed is a sparse 256 MiB file
with mkfs.btrfs's defaults for one device, and `--rootdir` keeps the staged
files' owner, so the files belong to the CI user, not root.

## The erofs seed

`bash scripts/erofs-capability-fixture.sh --dest NEW_DIR` builds `erofs.img`
and `payload.bin` with erofs-utils only. The tree is staged first, with its
hard link, its symbolic link and the `user.capability` xattr (set with
`setfattr`), and `mkfs.erofs` builds the image from it, so nothing writes the
image afterwards. It checks the seed with `fsck.erofs` and reads it through a
read-only kernel mount, never with this constellation's readers, and refuses
a seed whose names, bytes, hard link, symlink target, empty directory or
xattr disagree. `--check DIR` runs the executor over three rows. An erofs
image cannot be changed in place, so each row's probe runs `fsck.erofs` on
its copy, requires the copy to hash as the seed, and then marks the unused
block before the superblock at byte 1024; a reused copy or a write to the
source fixture fails the run. The Shell scripts job installs erofs-utils and
attr and runs both modes. A missing `mkfs.erofs`, `fsck.erofs`, `setfattr`,
`getfattr`, `mount` or `umount` fails naming its package before anything is
created; nothing is skipped. These tools are run as separate programs, as
oracles; nothing links or copies them.

| path | operand for |
|---|---|
| `/data.bin` (8 KiB, `user.capability=seed`) | stat, write --at, truncate, rm, xattr |
| `/dir/file.txt` | recursive ls, rm of a child, a nonempty rmdir refusal |
| `/empty` | rmdir, mkdir --parents below it |
| `/link-target.txt`, `/hardlink.txt` | hard links (one inode, link count 2) |
| `/symlink` -> `data.bin` | symbolic links |
| `/mv-src.txt`, `/replace-dst.txt` | mv, and mv onto an existing destination |
| `payload.bin` (4 KiB) | stdin for write rows |

EROFS format limits: EROFS is read-only, so a correct driver refuses every
verb that would change the image (exit 3), with the image byte-identical;
the operands exist so each refusal is made against a real target, not a
missing one. EROFS has no named data streams. The one xattr is in the `user`
namespace. The image is uncompressed, with mkfs.erofs's defaults (4 KiB
blocks), sized to its contents, and keeps the staged files' owner, so the
files belong to the CI user, not root.

This is the execution layer of #387 (#401) and its verified release
installation layer (#488, part of #402). Independent fixture builders are
tracked in #489–#495, and the measured seven-driver capability TSV in #496.
#403 owns CLI pipe workflow coverage and the measured output budget. Until
those follow-ups land, this checker does not establish that any released
driver implements a particular verb.
