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
#   the disk     sgdisk lays out a GPT disk of three partitions holding a
#                squashfs that mksquashfs made, an EROFS that mkfs.erofs
#                (erofs-utils) made, and an NTFS volume — mkfs.ntfs's own,
#                because the runner has no NTFS mkfs that is not GPL-linked
#                into a FUSE stack, holding the same file fs.ntfs wrote;
#   probe -> fs  blk.probe reads the disk, and each partition's `start` and
#                `fs_kind` choose the tool and its --offset: `fs.<fs_kind>
#                --offset <start> disk read /data.bin` must give back the
#                file's bytes. `start` is checked against sgdisk's own first
#                sector, and the same tool one block past `start` must NOT
#                give the bytes back, so the leg is one that can fail;
#   containers   qemu-img converts the disk to qcow2 and to VHDX. blk.probe
#                reads each container directly, `img.<fmt> read` turns it
#                back into a raw disk that must be byte-identical to the one
#                qemu-img was given, and the fs tools read from that;
#   fs -> fs     `fs.squashfs … read | fs.ntfs … write`, and the same from
#                EROFS, into the NTFS partition of the same disk, compared by
#                SHA-256 on the way back out; then fsck.ntfs over the volume,
#                both read-only neighbours re-read, and sgdisk -v on the table.
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
# Not here yet, because the tools do not exist as released tarballs: every
# leg with ext4 (rust-fs-ext4's release carries mkfs.ext4 only), XFS and
# Btrfs as endpoints, and VHD/VMDK containers. They join as their releases
# land; #292 lists them.
#
# Quiet, like the test tiers: the whole run goes to tmp/logs/cli-pipe.log
# through scripts/quiet-run.sh, and a pass prints one verdict line.
#
#   scripts/cli-pipe.sh [--verbose] [--no-install]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# Every pipeline below ends in a byte comparison and is counted. 3 partitions
# read through the raw disk, the qcow2 and the VHDX, plus 2 fs -> fs copies.
FLOOR=11

# The released tools. One row per repository: the asset prefix its release
# workflow names tarballs with, and the tools this test needs from it. Only
# those tools are put on PATH — rust-fs-erofs also ships a mkfs.erofs, and
# the EROFS here must be erofs-utils', not ours.
#
# repository                          asset prefix     tools
TOOLS='antimatter-studios/rust-blk-probe   rust-blk-probe   blk.probe
christhomas/rust-fs-ntfs            am-fs-ntfs       fs.ntfs mkfs.ntfs fsck.ntfs
antimatter-studios/rust-fs-squashfs am-fs-squashfs   fs.squashfs
antimatter-studios/rust-fs-erofs    am-fs-erofs      fs.erofs
antimatter-studios/rust-img-qcow2   am-img-qcow2     img.qcow2
antimatter-studios/rust-img-vhdx    am-img-vhdx      img.vhdx'

# The oracles: tools that are not ours, and how to get each.
# tool        brew           apt
ORACLES='sgdisk      gptfdisk       gdisk
qemu-img    qemu           qemu-utils
mksquashfs  squashfs       squashfs-tools
mkfs.erofs  erofs-utils    erofs-utils
jq          jq             jq'

STATE="${CLI_PIPE_DIR:-$ROOT/tmp/cli-pipe}"

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
    else shasum -a 256 | cut -d' ' -f1; fi
}

# ------------------------------------------------------------------ install
# install_tools DIR — every row of TOOLS from its latest release into DIR,
# verified, with the named tools linked into DIR/bin. Exits on the first
# refusal; nothing unverified is ever linked.
install_tools() {
    local dir="$1" platform os arch
    os="$(uname -s)" arch="$(uname -m)"
    case "$os/$arch" in
        Darwin/arm64)  platform=darwin-arm64 ;;
        Linux/x86_64)  platform=linux-x86_64 ;;
        *) echo "cli-pipe: no released tarballs are built for $os/$arch (darwin-arm64 and linux-x86_64 are)"; return 1 ;;
    esac
    command -v gh >/dev/null 2>&1 || { echo "cli-pipe: gh is not installed; it downloads each release and verifies its attestation"; return 1; }
    rm -rf "$dir"; mkdir -p "$dir/bin" "$dir/dl" || return 1
    local repo prefix tools tag asset actual expected pkg tool
    while read -r repo prefix tools; do
        [ -n "$repo" ] || continue
        tag="$(gh release view --repo "$repo" --json tagName -q .tagName 2>/dev/null)"
        [ -n "$tag" ] || { echo "cli-pipe: $repo has no release to install"; return 1; }
        asset="$prefix-${tag#v}-$platform.tar.gz"
        gh release download "$tag" --repo "$repo" --pattern "$asset" --dir "$dir/dl" >/dev/null 2>&1 \
            && [ -f "$dir/dl/$asset" ] \
            || { echo "cli-pipe: the $tag release of $repo has no $asset"; return 1; }
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
            [ -x "$pkg/bin/$tool" ] || { echo "cli-pipe: $asset ($repo $tag) has no bin/$tool"; return 1; }
            ln -sf "$pkg/bin/$tool" "$dir/bin/$tool"
        done
        echo "installed $repo $tag: $asset sha256 $actual, attestation verified"
    done <<EOF
$TOOLS
EOF
}

# require_tools — every tool this test runs is on PATH, or the run fails
# naming each one that is not and where it comes from.
require_tools() {
    local missing=0 repo prefix tools tool brew apt
    while read -r repo prefix tools; do
        [ -n "$repo" ] || continue
        for tool in $tools; do
            command -v "$tool" >/dev/null 2>&1 && continue
            echo "MISSING $tool — from $repo's release (scripts/cli-pipe.sh installs it), or brew install antimatter-studios/tap/${repo#*/}"
            missing=$((missing + 1))
        done
    done <<EOF
$TOOLS
EOF
    while read -r tool brew apt; do
        [ -n "$tool" ] || continue
        command -v "$tool" >/dev/null 2>&1 && continue
        echo "MISSING $tool — brew install $brew (or apt-get install $apt)"
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

# The partitions sgdisk lays out: slot, first sector, size, GPT type, and the
# fs_kind blk.probe must report for what is put there.
#   slot  sector  size  type  fs_kind
LAYOUT='0     2048    8M    8300  squashfs
1     18432   8M    8300  erofs
2     34816   16M   0700  ntfs'

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
    [ "$(jq '.partitions | length' "$json")" = 3 ] \
        || fail "$name: blk.probe reports $(jq '.partitions | length' "$json") partitions, not 3"

    local slot sector size type kind start got_kind tool got
    while read -r slot sector size type kind; do
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
$LAYOUT
EOF
}

# container_leg FMT — qemu-img makes the container; blk.probe reads it;
# img.<fmt> turns it back into the raw disk, and the fs tools read that.
container_leg() {
    local fmt="$1" image="$WORK/disk.$1" raw="$WORK/via-$1.raw"
    if ! qemu-img convert -f raw -O "$fmt" "$WORK/disk.img" "$image" > "$WORK/qemu.err" 2>&1; then
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
}

# copy_leg FROM_SLOT FROM_KIND — fs.<kind> read | fs.ntfs write, both by
# --offset into the one disk, compared by SHA-256 on the way back out.
copy_leg() {
    local from="$1" kind="$2" src_off dst_off dest got
    src_off="$(jq -r --argjson s "$from" '.partitions[] | select(.slot == $s) | .start' "$WORK/probe-raw.json")"
    dst_off="$(jq -r '.partitions[] | select(.slot == 2) | .start' "$WORK/probe-raw.json")"
    dest="/from-$kind.bin"
    if ! "fs.$kind" --offset "$src_off" "$WORK/disk.img" read /data.bin 2> "$WORK/src.err" \
        | fs.ntfs --offset "$dst_off" "$WORK/disk.img" write "$dest" 2> "$WORK/dst.err"; then
        fail "$kind -> ntfs: the pipe failed$(why "$WORK/src.err" "$WORK/dst.err")"
        return
    fi
    got="$(fs.ntfs --offset "$dst_off" "$WORK/disk.img" read "$dest" 2> "$WORK/read.err" | sha256)"
    pipelines=$((pipelines + 1))
    [ "$got" = "$SRC_SHA" ] \
        && ok "$kind -> ntfs: fs.$kind read | fs.ntfs write carries /data.bin byte for byte" \
        || fail "$kind -> ntfs: $dest reads back as sha256 $got, not $SRC_SHA$(why "$WORK/read.err")"
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

    # The filesystems, by their own projects' tools where one is installable.
    # mkfs.erofs gets -b 4096 explicitly: its default is the page size, 16K on
    # an arm64 Mac, and the block size is not what this test is about.
    mksquashfs "$WORK/src" "$WORK/p0.img" -noappend -quiet -no-xattrs -all-root > "$WORK/mk.log" 2>&1 \
        || { echo "cli-pipe: mksquashfs failed: $(tail -3 "$WORK/mk.log")"; exit 1; }
    mkfs.erofs -b4096 "$WORK/p1.img" "$WORK/src" > "$WORK/mk.log" 2>&1 \
        || { echo "cli-pipe: mkfs.erofs failed: $(tail -3 "$WORK/mk.log")"; exit 1; }
    mkfs.ntfs --size 16M --label PIPE "$WORK/p2.img" > "$WORK/mk.log" 2>&1 \
        || { echo "cli-pipe: mkfs.ntfs failed: $(tail -3 "$WORK/mk.log")"; exit 1; }
    fs.ntfs "$WORK/p2.img" write /data.bin < "$WORK/src/data.bin" > "$WORK/mk.log" 2>&1 \
        || { echo "cli-pipe: fs.ntfs could not write /data.bin into a fresh volume: $(tail -3 "$WORK/mk.log")"; exit 1; }

    # The disk: 40 MiB, a GPT sgdisk writes, each filesystem copied to the
    # first sector sgdisk gave its partition.
    dd if=/dev/zero of="$WORK/disk.img" bs=1048576 count=0 seek=40 2>/dev/null || exit 1
    local args=() slot sector size type kind
    while read -r slot sector size type kind; do
        [ -n "$slot" ] || continue
        args+=(-n "$((slot + 1)):$sector:+$size" -t "$((slot + 1)):$type" -c "$((slot + 1)):$kind")
    done <<EOF
$LAYOUT
EOF
    sgdisk -o "${args[@]}" "$WORK/disk.img" > "$WORK/mk.log" 2>&1 \
        || { echo "cli-pipe: sgdisk failed: $(tail -3 "$WORK/mk.log")"; exit 1; }
    while read -r slot sector size type kind; do
        [ -n "$slot" ] || continue
        dd if="$WORK/p$slot.img" of="$WORK/disk.img" bs=512 seek="$sector" conv=notrunc 2>/dev/null \
            || { echo "cli-pipe: could not copy $kind into slot $slot"; exit 1; }
    done <<EOF
$LAYOUT
EOF
    echo "the disk: $(sgdisk -p "$WORK/disk.img" | grep -cE '^ +[0-9]+ ') partitions, data.bin sha256 $SRC_SHA"

    probe_leg raw "$WORK/disk.img" "$WORK/disk.img"
    container_leg qcow2
    container_leg vhdx

    if [ -s "$WORK/probe-raw.json" ]; then
        copy_leg 0 squashfs
        copy_leg 1 erofs
        local ntfs_off
        ntfs_off="$(jq -r '.partitions[] | select(.slot == 2) | .start' "$WORK/probe-raw.json")"
        fsck.ntfs --offset "$ntfs_off" "$WORK/disk.img" > "$WORK/fsck.log" 2>&1 \
            && ok "fsck.ntfs finds the written volume clean" \
            || fail "fsck.ntfs refuses the volume the pipes wrote$(why "$WORK/fsck.log")"
        for slot in 0 1; do
            kind="$(jq -r --argjson s "$slot" '.partitions[] | select(.slot == $s) | .fs_kind' "$WORK/probe-raw.json")"
            [ "$("fs.$kind" --offset "$(jq -r --argjson s "$slot" '.partitions[] | select(.slot == $s) | .start' "$WORK/probe-raw.json")" "$WORK/disk.img" read /data.bin 2>/dev/null | sha256)" = "$SRC_SHA" ] \
                && ok "slot $slot ($kind) still reads after the NTFS writes beside it" \
                || fail "slot $slot ($kind) does not read after the NTFS writes beside it: did a write stray out of its partition?"
        done
        sgdisk -v "$WORK/disk.img" > "$WORK/verify.log" 2>&1 && grep -q 'No problems found' "$WORK/verify.log" \
            && ok "sgdisk -v finds the table intact" \
            || fail "sgdisk -v reports problems: $(grep -v '^$' "$WORK/verify.log" | head -3)"
    else
        fail "the fs -> fs legs need the raw disk's probe, and it did not run"
    fi

    echo "ran $pipelines pipeline(s) to a byte comparison (floor $FLOOR)"
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

# The quiet wrapper. Budget measured on CI; see chores.yml's table.
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
scripts/quiet-run.sh ${wrap[@]+"${wrap[@]}"} cli-pipe 200 20000 -- \
    bash scripts/cli-pipe.sh --run-all ${pass[@]+"${pass[@]}"} || rc=$?
log="${QUIET_LOG_DIR:-$ROOT/tmp/logs}/cli-pipe.log"
grep -E '^ran [0-9]+ pipeline' "$log" 2>/dev/null | tail -1
grep -E '^(FAIL|MISSING|cli-pipe: )' "$log" 2>/dev/null | grep -v 'all checks passed' | head -40
exit "$rc"
