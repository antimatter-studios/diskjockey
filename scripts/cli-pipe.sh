#!/usr/bin/env bash
#
# cli-pipe.sh — the drivers' released command-line tools compose (#292, #235).
#
# Each driver's own `cli` suite proves its tool against its own oracle. None
# of them can prove that the tools fit together, and that is the whole
# argument for raw bytes on `read`/`write` and for `blk.probe` handing out a
# byte offset: the offset one tool prints must be the one the next tool needs,
# and the bytes one tool reads must be the bytes the next one writes. This
# runs those pipelines end to end, against the RELEASED tools, on images made
# by tools that are not ours:
#
#   the disk     sgdisk lays out a GPT disk holding a squashfs that
#                mksquashfs made, an EROFS that mkfs.erofs (erofs-utils)
#                made, an ext4 that mke2fs (e2fsprogs) made, and an NTFS
#                volume — mkfs.ntfs's own, because no runner has an NTFS mkfs
#                that can populate a volume without a FUSE mount, holding the
#                same file fs.ntfs wrote. On Linux it also holds an XFS that
#                mkfs.xfs (xfsprogs) made from a protofile and a Btrfs that
#                mkfs.btrfs (btrfs-progs) made with --rootdir: neither has a
#                macOS build, so those two partitions, and the pairs that
#                use them, are the Linux leg's alone;
#   probe -> fs  blk.probe reads the disk, and each partition's `start` and
#                `fs_kind` choose the tool and its --offset: `fs.<fs_kind>
#                --offset <start> disk read /data.bin` must give back the
#                file's bytes. `start` is checked against sgdisk's own first
#                sector, and the same tool one block past `start` must NOT
#                give the bytes back, so the leg is one that can fail;
#   containers   qemu-img converts the disk to qcow2, VHDX, VHD and VMDK. blk.probe
#                reads each container directly, `img.<fmt> read` turns it
#                back into a raw disk that must be byte-identical to the one
#                qemu-img was given, and the fs tools read from that;
#   fs -> fs     every row of PAIRS: `fs.<a> … read | fs.<b> … write` into
#                partition b of the same disk, compared by SHA-256 on the way
#                back out. Then each destination's own checker (fsck.ntfs,
#                fsck.ext4) and an oracle's: e2fsck -fn and debugfs's `cat`
#                over the ext4, and on Linux ntfscat (ntfs-3g) over the NTFS,
#                each written file read back by the tool that is not ours;
#                every partition re-read, and sgdisk -v on the table.
#
# INSTALLED FROM RELEASES, VERIFIED. Each tool comes from its repository's
# latest GitHub release, the platform's tarball, refused unless its
# build-provenance attestation was signed by that repository's release
# workflow (and, where the release publishes one, its .sha256 matches): the
# same checks scripts/build-blk.probe.sh makes for the probe the app ships.
# Latest rather than pinned, because the question is whether what a user can
# install today composes. `--no-install` uses whatever is already on PATH
# instead, which is how a Homebrew install is tested:
#
#   brew install antimatter-studios/tap/rust-fs-ntfs …
#   scripts/cli-pipe.sh --no-install
#
# NOTHING SKIPS. A tool that is missing — ours or an oracle — fails the run
# before any leg starts, naming every one that is missing and how to install
# it. A FLOOR counts the pipelines that actually ran to a byte comparison, so
# a run that stops short is refused even when nothing it did run failed.
#
# TWO PLATFORMS. The CLI pipe workflow runs this on macos-26 and on
# ubuntu-latest. Each platform's partitions, pairs and floor are declared in
# the tables below — a row's `on` column is `all` or `linux` — so what the
# macOS leg does not run is written down, not skipped at run time.
#
# WAITING ON RELEASES. Some of the tools here have no release that carries
# them yet. The installer refuses each such release by name, every one in the
# same run, with the issue that tracks it (AWAITING below), and the run fails:
# a pipeline that cannot run yet is red until it can. Delete an AWAITING row
# when its release lands.
#
# Quiet, like the test tiers: the whole run goes to tmp/logs/cli-pipe.log
# through scripts/quiet-run.sh, and a pass prints one verdict line.
#
#   scripts/cli-pipe.sh [--verbose] [--no-install]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# Every pipeline below ends in a byte comparison and is counted: each
# partition read through the raw disk and four containers, plus each PAIRS
# row. macOS: 4 partitions x 5 + 5 pairs. Linux: 6 partitions x 5 + 7 pairs.
FLOOR_DARWIN=25
FLOOR_LINUX=37

case "$(uname -s)" in Darwin) HERE=darwin ;; *) HERE=linux ;; esac
FLOOR=$FLOOR_LINUX
[ "$HERE" = darwin ] && FLOOR=$FLOOR_DARWIN
# on_here ON — a table row whose `on` column is ON runs on this platform.
on_here() { [ "$1" = all ] || [ "$1" = "$HERE" ]; }

# The released tools. One row per repository: the asset prefix its release
# workflow names tarballs with, the platforms it is needed on, and the tools
# this test needs from it. Only those tools are put on PATH — rust-fs-erofs
# also ships a mkfs.erofs and rust-fs-ext4 a mkfs.ext4, and the EROFS and
# ext4 here must be erofs-utils' and e2fsprogs', not ours. On Linux the
# installed fsck.ext4 and mkfs.ntfs shadow e2fsprogs' and ntfs-3g's of the
# same name, because the install directory goes first on PATH; the oracles
# are called by the names only they have (e2fsck, mke2fs, debugfs, ntfscat).
#
# repository                          asset prefix     on     tools
TOOLS='antimatter-studios/rust-blk-probe   rust-blk-probe   all    blk.probe
christhomas/rust-fs-ntfs            am-fs-ntfs       all    fs.ntfs mkfs.ntfs fsck.ntfs
christhomas/rust-fs-ext4            am-fs-ext4       all    fs.ext4 fsck.ext4
antimatter-studios/rust-fs-squashfs am-fs-squashfs   all    fs.squashfs
antimatter-studios/rust-fs-erofs    am-fs-erofs      all    fs.erofs
antimatter-studios/rust-fs-xfs      am-fs-xfs        linux  fs.xfs
antimatter-studios/rust-fs-btrfs    am-fs-btrfs      linux  fs.btrfs
antimatter-studios/rust-img-qcow2   am-img-qcow2     all    img.qcow2
antimatter-studios/rust-img-vhdx    am-img-vhdx      all    img.vhdx
antimatter-studios/rust-img-vhd     am-img-vhd       all    img.vhd
antimatter-studios/rust-img-vmdk    am-img-vmdk      all    img.vmdk'

# Releases still to come: a repository whose latest release cannot give this
# test what it needs on a platform, and the issue that tracks the release
# that will. Printed beside the installer's refusal, so a red run names what
# it is waiting for. Delete the row when the release lands.
#
# repository                          on     waiting on
AWAITING='christhomas/rust-fs-ext4            all    a release with fs.ext4 and fsck.ext4 in its tarballs, christhomas/rust-fs-ext4#480
antimatter-studios/rust-fs-btrfs    all    a release with tarballs at all, antimatter-studios/rust-fs-btrfs#250
antimatter-studios/rust-blk-probe   linux  a release cut since antimatter-studios/rust-blk-probe#45 added the linux-x86_64 tarball'

# The oracles: tools that are not ours, how to get each, and where. XFS and
# Btrfs have no macOS build, and Homebrew's ntfs-3g needs macFUSE.
# tool        brew           apt              on
ORACLES='sgdisk      gptfdisk       gdisk            all
qemu-img    qemu           qemu-utils       all
mksquashfs  squashfs       squashfs-tools   all
mkfs.erofs  erofs-utils    erofs-utils      all
mke2fs      e2fsprogs      e2fsprogs        all
e2fsck      e2fsprogs      e2fsprogs        all
debugfs     e2fsprogs      e2fsprogs        all
jq          jq             jq               all
mkfs.xfs    -              xfsprogs         linux
mkfs.btrfs  -              btrfs-progs      linux
ntfscat     -              ntfs-3g          linux'

STATE="${CLI_PIPE_DIR:-$ROOT/tmp/cli-pipe}"

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
    else shasum -a 256 | cut -d' ' -f1; fi
}

# ------------------------------------------------------------------ install
# awaited REPO — " (waiting on …)" when AWAITING has a row for REPO on this
# platform, else nothing.
awaited() {
    local repo on note
    while read -r repo on note; do
        [ "$repo" = "$1" ] && on_here "$on" && { printf ' (waiting on %s)' "$note"; return; }
    done <<EOF
$AWAITING
EOF
}

# install_tools DIR — every row of TOOLS this platform needs, from its latest
# release into DIR, verified, with the named tools linked into DIR/bin. A
# refused release links nothing and the next row is still tried, so one run
# names every release it cannot install; then it fails.
install_tools() {
    local dir="$1" platform os arch refused=0
    os="$(uname -s)" arch="$(uname -m)"
    case "$os/$arch" in
        Darwin/arm64)  platform=darwin-arm64 ;;
        Linux/x86_64)  platform=linux-x86_64 ;;
        *) echo "cli-pipe: no released tarballs are built for $os/$arch (darwin-arm64 and linux-x86_64 are)"; return 1 ;;
    esac
    command -v gh >/dev/null 2>&1 || { echo "cli-pipe: gh is not installed; it downloads each release and verifies its attestation"; return 1; }
    rm -rf "$dir"; mkdir -p "$dir/bin" "$dir/dl" || return 1
    local repo prefix on tools
    while read -r repo prefix on tools; do
        [ -n "$repo" ] && on_here "$on" || continue
        install_one "$dir" "$platform" "$repo" "$prefix" "$tools" || refused=$((refused + 1))
    done <<EOF
$TOOLS
EOF
    [ "$refused" = 0 ] || { echo "cli-pipe: $refused release(s) could not be installed; nothing skips, so the run fails"; return 1; }
}

# install_one DIR PLATFORM REPO PREFIX TOOLS — one repository's release, or a
# refusal naming why (and what it is waiting on). Links only once every check
# has passed and every tool is in the tarball.
install_one() {
    local dir="$1" platform="$2" repo="$3" prefix="$4" tools="$5" tag asset actual expected pkg tool
    tag="$(gh release view --repo "$repo" --json tagName -q .tagName 2>/dev/null)"
    [ -n "$tag" ] || { echo "cli-pipe: $repo has no release to install$(awaited "$repo")"; return 1; }
    asset="$prefix-${tag#v}-$platform.tar.gz"
    gh release download "$tag" --repo "$repo" --pattern "$asset" --dir "$dir/dl" >/dev/null 2>&1 \
        && [ -f "$dir/dl/$asset" ] \
        || { echo "cli-pipe: the $tag release of $repo has no $asset$(awaited "$repo")"; return 1; }
    actual="$(sha256 < "$dir/dl/$asset")"
    if gh release download "$tag" --repo "$repo" --pattern "$asset.sha256" --dir "$dir/dl" >/dev/null 2>&1; then
        expected="$(awk '{print $1; exit}' "$dir/dl/$asset.sha256")"
        [ "$actual" = "$expected" ] \
            || { echo "cli-pipe: $asset is sha256 $actual, but its .sha256 says ${expected:-nothing}"; return 1; }
    fi
    gh attestation verify "$dir/dl/$asset" --repo "$repo" \
        --signer-workflow "$repo/.github/workflows/release.yml" >/dev/null 2>&1 \
        || { echo "cli-pipe: $asset has no attestation signed by $repo's release workflow; refusing it"; return 1; }
    pkg="$dir/pkg/$prefix"
    mkdir -p "$pkg" && tar -xzf "$dir/dl/$asset" -C "$pkg" || { echo "cli-pipe: $asset did not unpack"; return 1; }
    for tool in $tools; do
        [ -x "$pkg/bin/$tool" ] || { echo "cli-pipe: $asset ($repo $tag) has no bin/$tool$(awaited "$repo")"; return 1; }
    done
    for tool in $tools; do ln -sf "$pkg/bin/$tool" "$dir/bin/$tool"; done
    echo "installed $repo $tag: $asset sha256 $actual, attestation verified"
}

# require_tools — every tool this platform's run uses is on PATH, or the run
# fails naming each one that is not and where it comes from.
require_tools() {
    local missing=0 repo prefix on tools tool brew apt
    while read -r repo prefix on tools; do
        [ -n "$repo" ] && on_here "$on" || continue
        for tool in $tools; do
            command -v "$tool" >/dev/null 2>&1 && continue
            echo "MISSING $tool — from $repo's release (scripts/cli-pipe.sh installs it), or brew install antimatter-studios/tap/${repo#*/}"
            missing=$((missing + 1))
        done
    done <<EOF
$TOOLS
EOF
    while read -r tool brew apt on; do
        [ -n "$tool" ] && on_here "$on" || continue
        command -v "$tool" >/dev/null 2>&1 && continue
        if [ "$brew" = - ]; then echo "MISSING $tool — apt-get install $apt (it has no macOS build)"
        else echo "MISSING $tool — brew install $brew (or apt-get install $apt)"; fi
        missing=$((missing + 1))
    done <<EOF
$ORACLES
EOF
    [ "$missing" = 0 ] || { echo "cli-pipe: $missing tool(s) missing; nothing skips, so the run fails"; return 1; }
}

# --------------------------------------------------------------------- legs
fails=0
pipelines=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
# why FILE... — the first lines of what a tool said on stderr, if it said
# anything, as a suffix for a FAIL line.
why() { local t; t="$(cat "$@" 2>/dev/null | grep -v '^$' | head -3 | tr '\n' ' ')"; [ -z "$t" ] || printf ' — %s' "$t"; }

# The partitions sgdisk lays out: slot, first sector, size, GPT type, the
# fs_kind blk.probe must report for what is put there, and where it runs.
# The Linux-only rows come last, so the slots stay contiguous on macOS. XFS
# is 320M because current mkfs.xfs refuses anything under 300 MiB. Btrfs is
# 128M because mkfs.btrfs's minimum device is 109 MiB (114,294,784 bytes)
# and on a regular file it extends the file rather than refusing: with a 64M
# row the copy ran past the disk's end, so sgdisk found no backup GPT at the
# last LBA (run 37138277392). The caller of make_fs now refuses any image
# larger than its partition, so an overrun names itself.
#   slot  sector  size  type  fs_kind   on
LAYOUT='0     2048    8M    8300  squashfs  all
1     18432   8M    8300  erofs     all
2     34816   16M   0700  ntfs      all
3     67584   16M   8300  ext4      all
4     100352  320M  8300  xfs       linux
5     755712  128M  8300  btrfs     linux'

# The fs -> fs pipelines: `fs.<from> read /data.bin | fs.<to> write
# /from-<from>.bin`, both by --offset into the same disk.
#   from      to    on
PAIRS='squashfs  ntfs  all
erofs     ntfs  all
ext4      ntfs  all
ntfs      ext4  all
erofs     ext4  all
xfs       ext4  linux
btrfs     ntfs  linux'

# here TABLE COLUMN — TABLE's rows whose column COLUMN (`on`) runs here.
here() { printf '%s\n' "$1" | awk -v c="$2" -v p="$HERE" 'NF && ($c == "all" || $c == p)'; }
LAYOUT_HERE="$(here "$LAYOUT" 6)"
PAIRS_HERE="$(here "$PAIRS" 3)"
NPARTS="$(printf '%s\n' "$LAYOUT_HERE" | grep -c .)"

# start_of KIND — the byte offset the raw disk's probe gives KIND's slot.
start_of() {
    local slot
    slot="$(printf '%s\n' "$LAYOUT_HERE" | awk -v k="$1" '$5 == k { print $1; exit }')"
    [ -n "$slot" ] || return 0
    jq -r --argjson s "$slot" '.partitions[] | select(.slot == $s) | .start' "$WORK/probe-raw.json"
}

# extract KIND FILE — KIND's partition copied out of the disk, for an oracle
# that takes no offset. The sector and size are sgdisk's, not the probe's.
extract() {
    local sector size
    read -r sector size <<EOF
$(printf '%s\n' "$LAYOUT_HERE" | awk -v k="$1" '$5 == k { print $2, $3 + 0; exit }')
EOF
    dd if="$WORK/disk.img" of="$2" bs=1048576 skip="$((sector / 2048))" count="$size" 2>/dev/null
}

# probe_leg NAME PROBED RAW — blk.probe reads PROBED; every partition it
# reports is read through fs.<fs_kind> --offset <start> out of RAW.
probe_leg() {
    local name="$1" probed="$2" raw="$3" json want_container
    json="$WORK/probe-$name.json"
    if ! blk.probe "$probed" > "$json" 2> "$WORK/probe-$name.err"; then
        fail "$name: blk.probe $probed exited non-zero$(why "$WORK/probe-$name.err")"
        return
    fi
    want_container="$name"
    [ "$name" = raw ] && want_container=raw
    [ "$(jq -r .container "$json")" = "$want_container" ] \
        && ok "$name: blk.probe names the container $want_container" \
        || fail "$name: blk.probe names the container '$(jq -r .container "$json")', not $want_container"
    [ "$(jq -r .table "$json")" = gpt ] \
        && ok "$name: blk.probe finds the GPT" \
        || fail "$name: blk.probe reports table '$(jq -r .table "$json")', not gpt"
    [ "$(jq '.partitions | length' "$json")" = "$NPARTS" ] \
        || fail "$name: blk.probe reports $(jq '.partitions | length' "$json") partitions, not $NPARTS"

    local slot sector size type kind on start got_kind tool got
    while read -r slot sector size type kind on; do
        [ -n "$slot" ] || continue
        start="$(jq -r --argjson s "$slot" '.partitions[] | select(.slot == $s) | .start' "$json")"
        got_kind="$(jq -r --argjson s "$slot" '.partitions[] | select(.slot == $s) | .fs_kind' "$json")"
        if [ -z "$start" ] || [ "$start" = null ]; then
            fail "$name: blk.probe reports no partition in slot $slot"
            continue
        fi
        # The oracle for the offset is the tool that wrote the table.
        [ "$start" = "$((sector * 512))" ] \
            && ok "$name: slot $slot starts at $start, where sgdisk put it" \
            || fail "$name: blk.probe says slot $slot starts at $start; sgdisk put it at $((sector * 512))"
        [ "$got_kind" = "$kind" ] \
            && ok "$name: slot $slot is $kind" \
            || fail "$name: blk.probe says slot $slot is '$got_kind', but it holds $kind"
        # The pipe: the probe's own answers pick the tool and the offset.
        tool="fs.$got_kind"
        if ! command -v "$tool" >/dev/null 2>&1; then
            fail "$name: blk.probe routed slot $slot to $tool, which is not installed"
            continue
        fi
        # ext4 is listed as well as read, through every container (#296).
        if [ "$got_kind" = ext4 ]; then
            "$tool" --offset "$start" "$raw" ls / 2> "$WORK/ls.err" | grep 'data\.bin' >/dev/null \
                && ok "$name: $tool --offset $start ls / lists data.bin" \
                || fail "$name: $tool --offset $start ls / does not list data.bin$(why "$WORK/ls.err")"
        fi
        got="$("$tool" --offset "$start" "$raw" read /data.bin 2> "$WORK/read.err" | sha256)"
        pipelines=$((pipelines + 1))
        [ "$got" = "$SRC_SHA" ] \
            && ok "$name: blk.probe | $tool --offset $start read /data.bin gives back its bytes" \
            || fail "$name: $tool --offset $start read /data.bin gave sha256 $got, not $SRC_SHA$(why "$WORK/read.err")"
        # And the link can break: one block past the start is not the file.
        got="$("$tool" --offset "$((start + 4096))" "$raw" read /data.bin 2>/dev/null | sha256)"
        [ "$got" != "$SRC_SHA" ] \
            && ok "$name: $tool one block past slot $slot's start does not give the bytes back" \
            || fail "$name: $tool read the file at the wrong offset $((start + 4096)), so this leg cannot tell a broken link from a working one"
    done <<EOF
$LAYOUT_HERE
EOF
}

# container_leg FMT QEMU_FMT [QEMU_OPTS] — qemu-img makes the container;
# blk.probe reads it; img.<fmt> turns it back into the raw disk, and the fs
# tools read that.
container_leg() {
    local fmt="$1" qfmt="$2" image="$WORK/disk.$1" raw="$WORK/via-$1.raw"
    shift 2
    if ! qemu-img convert -f raw -O "$qfmt" "$@" "$WORK/disk.img" "$image" > "$WORK/qemu.err" 2>&1; then
        fail "$fmt: qemu-img could not make the $fmt container$(why "$WORK/qemu.err")"
        return
    fi
    if ! "img.$fmt" "$image" read -o "$raw" 2> "$WORK/img.err"; then
        fail "$fmt: img.$fmt $image read -o exited non-zero$(why "$WORK/img.err")"
        return
    fi
    cmp -s "$raw" "$WORK/disk.img" \
        && ok "$fmt: img.$fmt read gives back the exact disk qemu-img was given" \
        || fail "$fmt: img.$fmt read does not give back the disk qemu-img was given ($(cmp "$raw" "$WORK/disk.img" 2>&1 | head -1))"
    probe_leg "$fmt" "$image" "$raw"
    # The raw copy has been read; a Linux disk is 433 MiB, four times over.
    rm -f "$raw" "$image"
}

# copy_leg FROM TO — fs.<FROM> read | fs.<TO> write, both by --offset into
# the one disk, compared by SHA-256 on the way back out.
copy_leg() {
    local from="$1" to="$2" src_off dst_off dest got
    src_off="$(start_of "$from")" dst_off="$(start_of "$to")"
    case "$src_off:$dst_off" in
        :*|*:|null:*|*:null) fail "$from -> $to: the raw disk's probe gave no start for $from or for $to"; return ;;
    esac
    dest="/from-$from.bin"
    if ! "fs.$from" --offset "$src_off" "$WORK/disk.img" read /data.bin 2> "$WORK/src.err" \
        | "fs.$to" --offset "$dst_off" "$WORK/disk.img" write "$dest" 2> "$WORK/dst.err"; then
        fail "$from -> $to: the pipe failed$(why "$WORK/src.err" "$WORK/dst.err")"
        return
    fi
    got="$("fs.$to" --offset "$dst_off" "$WORK/disk.img" read "$dest" 2> "$WORK/read.err" | sha256)"
    pipelines=$((pipelines + 1))
    [ "$got" = "$SRC_SHA" ] \
        && ok "$from -> $to: fs.$from read | fs.$to write carries /data.bin byte for byte" \
        || fail "$from -> $to: $dest reads back as sha256 $got, not $SRC_SHA$(why "$WORK/read.err")"
}

# check_written — each destination's own checker over the volume the pipes
# wrote, then the oracles': e2fsck and debugfs over the ext4, ntfscat over
# the NTFS on Linux, each reading back every file written there.
check_written() {
    local to from off part got oracle
    for to in $(printf '%s\n' "$PAIRS_HERE" | awk '{ print $2 }' | sort -u); do
        off="$(start_of "$to")"
        "fsck.$to" --offset "$off" "$WORK/disk.img" > "$WORK/fsck-$to.log" 2>&1 \
            && ok "fsck.$to finds the $to volume the pipes wrote clean" \
            || fail "fsck.$to refuses the $to volume the pipes wrote$(why "$WORK/fsck-$to.log")"
        part="$WORK/$to.part"
        case "$to" in
            ext4)
                extract ext4 "$part" || { fail "could not copy the ext4 partition out for e2fsck"; continue; }
                e2fsck -fn "$part" > "$WORK/e2fsck.log" 2>&1 \
                    && ok "e2fsck -fn finds the ext4 the pipes wrote clean" \
                    || fail "e2fsck -fn refuses the ext4 the pipes wrote$(why "$WORK/e2fsck.log")" ;;
            ntfs)
                [ "$HERE" = linux ] || continue
                extract ntfs "$part" || { fail "could not copy the NTFS partition out for ntfscat"; continue; } ;;
        esac
        for from in $(printf '%s\n' "$PAIRS_HERE" | awk -v t="$to" '$2 == t { print $1 }'); do
            case "$to" in
                ext4) got="$(debugfs -R "cat /from-$from.bin" "$part" 2> "$WORK/oracle.err" | sha256)"; oracle=debugfs ;;
                ntfs) got="$(ntfscat "$part" "/from-$from.bin" 2> "$WORK/oracle.err" | sha256)"; oracle=ntfscat ;;
            esac
            [ "$got" = "$SRC_SHA" ] \
                && ok "$oracle reads /from-$from.bin out of the $to volume byte for byte" \
                || fail "$oracle reads /from-$from.bin out of the $to volume as sha256 $got, not $SRC_SHA$(why "$WORK/oracle.err")"
        done
    done
}

# make_fs KIND SIZE FILE — KIND made by its own project's tool where one is
# installable, holding $WORK/src/data.bin.
make_fs() {
    local kind="$1" size="$2" file="$3"
    case "$kind" in
        squashfs) mksquashfs "$WORK/src" "$file" -noappend -quiet -no-xattrs -all-root ;;
        # -b 4096 explicitly: mkfs.erofs's default is the page size, 16K on an
        # arm64 Mac, and the block size is not what this test is about.
        erofs) mkfs.erofs -b4096 "$file" "$WORK/src" ;;
        ntfs) mkfs.ntfs --size "$size" --label PIPE "$file" \
                && fs.ntfs "$file" write /data.bin < "$WORK/src/data.bin" ;;
        ext4) dd if=/dev/zero of="$file" bs=1048576 count=0 seek="${size%M}" 2>/dev/null \
                && mke2fs -q -F -t ext4 -b 4096 -L PIPE -d "$WORK/src" "$file" ;;
        # A protofile: the boot-image line mkfs.xfs ignores, block and inode
        # counts it takes from the device, the root, its one file, and `$`.
        xfs) dd if=/dev/zero of="$file" bs=1048576 count=0 seek="${size%M}" 2>/dev/null \
                && printf '/dev/null\n0 0\nd--755 0 0\ndata.bin ---644 0 0 %s\n$\n' "$WORK/src/data.bin" > "$WORK/xfs.proto" \
                && mkfs.xfs -q -f -L PIPE -p "$WORK/xfs.proto" "$file" ;;
        btrfs) dd if=/dev/zero of="$file" bs=1048576 count=0 seek="${size%M}" 2>/dev/null \
                && mkfs.btrfs -q -f -L PIPE --rootdir "$WORK/src" "$file" ;;
        *) echo "no maker for $kind"; return 1 ;;
    esac
}

run_all() {
    if [ "${1:-}" != --no-install ]; then
        install_tools "$STATE/tools" || exit 1
        PATH="$STATE/tools/bin:$PATH"
    fi
    require_tools || exit 1

    WORK="$STATE/work"
    rm -rf "$WORK"; mkdir -p "$WORK/src" || exit 1

    # The content: one file of a few hundred KiB, so a read crosses many
    # blocks and any fragment boundary, not a one-block toy.
    head -c 300000 /dev/urandom > "$WORK/src/data.bin"
    SRC_SHA="$(sha256 < "$WORK/src/data.bin")"

    local args=() slot sector size type kind on disk_mib
    while read -r slot sector size type kind on; do
        [ -n "$slot" ] || continue
        make_fs "$kind" "$size" "$WORK/p$slot.img" > "$WORK/mk.log" 2>&1 \
            || { echo "cli-pipe: could not make the $kind for slot $slot: $(tail -3 "$WORK/mk.log")"; exit 1; }
        # A maker that grows its file past the partition would be copied
        # over the next partition or past the disk's end, behind the GPT.
        [ "$(wc -c < "$WORK/p$slot.img")" -le "$(( ${size%M} * 1048576 ))" ] \
            || { echo "cli-pipe: the $kind for slot $slot is $(wc -c < "$WORK/p$slot.img") bytes, larger than its $size partition"; exit 1; }
        args+=(-n "$((slot + 1)):$sector:+$size" -t "$((slot + 1)):$type" -c "$((slot + 1)):$kind")
    done <<EOF
$LAYOUT_HERE
EOF

    # The disk: a GPT sgdisk writes, a MiB past the last partition for its
    # backup table, each filesystem copied to the first sector sgdisk gave
    # its partition (every one MiB-aligned).
    disk_mib="$(printf '%s\n' "$LAYOUT_HERE" | awk '{ e = $2 / 2048 + $3; if (e > m) m = e } END { print m + 1 }')"
    dd if=/dev/zero of="$WORK/disk.img" bs=1048576 count=0 seek="$disk_mib" 2>/dev/null || exit 1
    sgdisk -o "${args[@]}" "$WORK/disk.img" > "$WORK/mk.log" 2>&1 \
        || { echo "cli-pipe: sgdisk failed: $(tail -3 "$WORK/mk.log")"; exit 1; }
    while read -r slot sector size type kind on; do
        [ -n "$slot" ] || continue
        dd if="$WORK/p$slot.img" of="$WORK/disk.img" bs=1048576 seek="$((sector / 2048))" conv=notrunc 2>/dev/null \
            || { echo "cli-pipe: could not copy $kind into slot $slot"; exit 1; }
        rm -f "$WORK/p$slot.img"
    done <<EOF
$LAYOUT_HERE
EOF
    echo "the disk ($HERE): $(sgdisk -p "$WORK/disk.img" | grep -cE '^ +[0-9]+ ') partitions, data.bin sha256 $SRC_SHA"

    probe_leg raw "$WORK/disk.img" "$WORK/disk.img"
    container_leg qcow2 qcow2
    container_leg vhdx vhdx
    # force_size: qemu's VHD otherwise rounds the disk to a CHS geometry, and
    # the round trip would differ from the disk by that rounding.
    container_leg vhd vpc -o force_size=on
    container_leg vmdk vmdk

    if [ -s "$WORK/probe-raw.json" ]; then
        local from to
        while read -r from to on; do
            [ -n "$from" ] && copy_leg "$from" "$to"
        done <<EOF
$PAIRS_HERE
EOF
        check_written
        # Every partition still reads: a write that strayed out of its own
        # partition would show here.
        while read -r slot sector size type kind on; do
            [ -n "$slot" ] || continue
            [ "$("fs.$kind" --offset "$(start_of "$kind")" "$WORK/disk.img" read /data.bin 2>/dev/null | sha256)" = "$SRC_SHA" ] \
                && ok "slot $slot ($kind) still reads /data.bin after the writes" \
                || fail "slot $slot ($kind) does not read /data.bin after the writes: did a write stray out of its partition?"
        done <<EOF
$LAYOUT_HERE
EOF
        sgdisk -v "$WORK/disk.img" > "$WORK/verify.log" 2>&1 && grep -q 'No problems found' "$WORK/verify.log" \
            && ok "sgdisk -v finds the table intact" \
            || fail "sgdisk -v reports problems: $(grep -v '^$' "$WORK/verify.log" | head -3)"
    else
        fail "the fs -> fs legs need the raw disk's probe, and it did not run"
    fi

    echo "ran $pipelines pipeline(s) to a byte comparison (floor $FLOOR, $HERE)"
    [ "$pipelines" -ge "$FLOOR" ] \
        || fail "only $pipelines pipelines reached a comparison, floor is $FLOOR: the run stopped short"
    echo
    if [ "$fails" -eq 0 ]; then echo "cli-pipe: all checks passed"; exit 0; fi
    echo "cli-pipe: $fails check(s) failed"
    exit 1
}

if [ "${1:-}" = --run-all ]; then
    shift
    run_all "$@"
fi

# The quiet wrapper. The budget is chores.yml's cli-pipe row: 152 lines /
# 9,252 bytes measured on macOS on run 37138277392 (25 pipelines, every check
# passed), about a quarter over. Linux runs 37 pipelines and has not yet had
# a green run to measure. A pass over budget exits 65, and the first green
# Linux run is the measurement to raise the row with.
wrap=() pass=()
for a in "$@"; do
    case "$a" in
        --verbose)    wrap+=("$a") ;;
        --no-install) pass+=("$a") ;;
        *) echo "usage: scripts/cli-pipe.sh [--verbose] [--no-install]" >&2; exit 2 ;;
    esac
done
rc=0
# ${a[@]+"${a[@]}"}: an empty array is "unbound" to macOS's bash 3.2.
scripts/quiet-run.sh ${wrap[@]+"${wrap[@]}"} cli-pipe 190 11600 -- \
    bash scripts/cli-pipe.sh --run-all ${pass[@]+"${pass[@]}"} || rc=$?
log="${QUIET_LOG_DIR:-$ROOT/tmp/logs}/cli-pipe.log"
grep -E '^ran [0-9]+ pipeline' "$log" 2>/dev/null | tail -1
grep -E '^(FAIL|MISSING|cli-pipe: )' "$log" 2>/dev/null | grep -v 'all checks passed' | head -40
exit "$rc"
