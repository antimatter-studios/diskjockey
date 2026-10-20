#!/usr/bin/env bash
# shellcheck disable=SC2015 # each && chain is the check; its || arm reports it
# Build and independently check the ntfs capability seed (#490, part of #402).
#
#   --dest NEW_DIR   build NEW_DIR/ntfs.img and NEW_DIR/payload.bin with
#                    ntfs-3g only, then verify them with ntfsls, ntfscat and
#                    ntfsinfo
#   --check DIR      prove the capability executor gives every operation a
#                    fresh copy of DIR/ntfs.img, using an ntfscp probe tool
#
# The seed is formatted by mkntfs and populated through an ntfs-3g FUSE mount,
# never by this constellation's writers, and read back from the unmounted
# image by ntfsls, ntfscat and ntfsinfo, never by our readers. All of them run
# at arm's length as command-line tools; nothing is linked or copied. A
# missing builder fails naming the package that supplies it; nothing is
# skipped.
set -uo pipefail
# Builtins only until the builders are found: the refusal guard runs this
# with a PATH that holds none of them.
here="${BASH_SOURCE[0]%/*}"
[ "$here" = "${BASH_SOURCE[0]}" ] && here=.
ROOT="$(cd "$here/.." && pwd)"
usage() {
    echo 'usage: scripts/ntfs-capability-fixture.sh --dest NEW_DIR | --check DIR' >&2
    exit 2
}
fails=0
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

require_builders() {
    local tool missing=0
    for tool in mkntfs ntfs-3g ntfscp ntfscat ntfsinfo ntfsls setfattr truncate sha256sum cmp mktemp; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            case "$tool" in
                mkntfs|ntfs-3g|ntfscp|ntfscat|ntfsinfo|ntfsls)
                    echo "ntfs-capability-fixture: missing $tool; install ntfs-3g (apt-get install ntfs-3g)" >&2 ;;
                setfattr)
                    echo "ntfs-capability-fixture: missing $tool; install attr (apt-get install attr)" >&2 ;;
                *)
                    echo "ntfs-capability-fixture: missing $tool; install coreutils" >&2 ;;
            esac
            missing=1
        fi
    done
    [ "$missing" = 0 ]
}

# The FUSE mount needs root; CI runs as a user with passwordless sudo.
as_root() {
    if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi
}

# The seed's shape. Every capability verb gets a valid operand:
#   /data.bin           8 KiB regular file: stat, write --at, truncate, rm,
#                       and the named data stream data.bin:capability = seed
#   /dir/file.txt       nonempty directory: ls -R, rm of a child, mv into
#   /empty              empty directory: rmdir, mkdir --parents below it
#   /link-target.txt    hard-link source, already linked as /hardlink.txt
#   /symlink            symbolic link to data.bin
#   /mv-src.txt         mv source
#   /replace-dst.txt    existing mv/replace destination
#   payload.bin         4 KiB stdin payload for write rows
# ntfs-3g exposes named data streams as user.* xattrs, so the one stream is
# both the stream operand and the xattr operand.
build() {
    local dest="$1" tree mnt out i
    [ ! -e "$dest" ] || { echo "ntfs-capability-fixture: $dest exists; give a new directory" >&2; return 1; }
    mkdir -p "$dest" || return 1
    tree="$(mktemp -d)" || return 1
    mnt="$(mktemp -d)" || return 1
    # shellcheck disable=SC2064
    trap "as_root umount '$mnt' 2>/dev/null; rm -rf '$tree' '$mnt'" EXIT
    mkdir "$tree/dir" "$tree/empty"
    for i in $(seq 0 1023); do printf 'data%04d' "$i"; done > "$tree/data.bin"
    printf 'nonempty directory child\n' > "$tree/dir/file.txt"
    printf 'hard link target\n' > "$tree/link-target.txt"
    printf 'move source\n' > "$tree/mv-src.txt"
    printf 'replace destination\n' > "$tree/replace-dst.txt"
    for i in $(seq 0 511); do printf 'pay%05d' "$i"; done > "$dest/payload.bin"
    sha256sum "$tree/data.bin" | cut -d' ' -f1 > "$dest/data.bin.sha256"

    # -F formats a regular file, -Q skips zeroing, -T zeroes the timestamps.
    truncate -s 32M "$dest/ntfs.img" || return 1
    # Their geometry warnings for a plain file are printed only on failure.
    out="$(mkntfs -q -F -Q -T -L capability "$dest/ntfs.img" 2>&1)" \
        || { printf '%s\n' "$out" >&2; echo 'ntfs-capability-fixture: mkntfs failed' >&2; return 1; }
    out="$(as_root ntfs-3g -o streams_interface=xattr "$dest/ntfs.img" "$mnt" 2>&1)" \
        || { printf '%s\n' "$out" >&2; echo 'ntfs-capability-fixture: ntfs-3g mount failed' >&2; return 1; }
    as_root cp -R "$tree/." "$mnt/" \
        && as_root ln "$mnt/link-target.txt" "$mnt/hardlink.txt" \
        && as_root ln -s data.bin "$mnt/symlink" \
        && as_root setfattr -n user.capability -v seed "$mnt/data.bin" \
        || { as_root umount "$mnt"; echo 'ntfs-capability-fixture: populating the seed failed' >&2; return 1; }
    as_root umount "$mnt" || { echo 'ntfs-capability-fixture: unmount failed' >&2; return 1; }
    verify "$dest"
}

# Read the unmounted seed back through ntfs-3g's own tools, not our drivers.
verify() {
    local dest="$1" img="$1/ntfs.img" root want inode_a inode_b
    ntfsinfo -m "$img" >/dev/null 2>&1 || fail 'ntfsinfo cannot read the volume'
    root="$(ntfsls -F -p / "$img" 2>/dev/null)"
    for want in data.bin dir/ empty/ link-target.txt hardlink.txt symlink mv-src.txt replace-dst.txt; do
        printf '%s\n' "$root" | grep -qx -- "${want}[@*]\{0,1\}" || fail "ntfsls lists no /$want"
    done
    [ "$(ntfscat "$img" /data.bin 2>/dev/null | sha256sum | cut -d' ' -f1)" = "$(cat "$dest/data.bin.sha256")" ] \
        || fail 'ntfscat reads /data.bin with the wrong bytes'
    ntfsls -p /dir "$img" 2>/dev/null | grep -qx 'file.txt' || fail '/dir is not nonempty'
    [ -z "$(ntfsls -p /empty "$img" 2>/dev/null | grep -vx '\.')" ] && ntfsinfo -F /empty "$img" >/dev/null 2>&1 \
        || fail '/empty is not an empty directory'
    # Two names on one MFT record is a hard link with a link count of 2.
    inode_a="$(ntfsls -i -p / "$img" 2>/dev/null | awk '$NF == "link-target.txt" { print $1 }')"
    inode_b="$(ntfsls -i -p / "$img" 2>/dev/null | awk '$NF == "hardlink.txt" { print $1 }')"
    [ -n "$inode_a" ] && [ "$inode_a" = "$inode_b" ] || fail '/hardlink.txt is not a hard link of /link-target.txt'
    # ntfs-3g stores a symlink as an Interix file ($DATA) or as a reparse
    # point ($REPARSE_POINT, 0xc0); either names data.bin in UTF-16.
    { ntfscat "$img" /symlink 2>/dev/null || :; ntfscat -a 0xc0 "$img" /symlink 2>/dev/null || :; } \
        | tr -d '\000' | grep -aq 'data\.bin' || fail '/symlink does not point at data.bin'
    # The named $DATA (0x80) attribute "capability" is the stream.
    [ "$(ntfscat -a 0x80 -n capability "$img" /data.bin 2>/dev/null)" = seed ] \
        || [ "$(ntfscat -a 128 -n capability "$img" /data.bin 2>/dev/null)" = seed ] \
        || fail '/data.bin has no capability stream holding seed'
    [ "$(wc -c < "$dest/payload.bin")" -eq 4096 ] || fail 'payload.bin is not 4096 bytes'
    [ "$fails" = 0 ] || return 1
    echo "ntfs-capability-fixture: seed verified by ntfsls, ntfscat and ntfsinfo in $dest"
}

# Every row overwrites /data.bin in its image. If the executor reused a copy,
# or handed the driver the source fixture, a later row would find it marked.
check() {
    local dir="$1" work before
    [ -f "$dir/ntfs.img" ] || { echo "ntfs-capability-fixture: no $dir/ntfs.img; build it with --dest" >&2; return 1; }
    work="$(mktemp -d)" || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT
    mkdir "$work/bin"
    for i in $(seq 0 1023); do printf 'mark%04d' "$i"; done > "$work/mark.bin"
    cat > "$work/bin/fs.ntfs" <<PROBE
#!/usr/bin/env bash
# Probe, not a driver: ntfscp marks /data.bin only if it is still the seed's.
[ "\${2:-}" = mark-probe ] || exit 2
[ "\$(ntfscat "\$1" /data.bin 2>/dev/null | head -c 8)" = data0000 ] || { echo 'stale copy: /data.bin already marked' >&2; exit 1; }
ntfscp "\$1" '$work/mark.bin' /data.bin >/dev/null 2>&1 || exit 1
[ "\$(ntfscat "\$1" /data.bin 2>/dev/null | head -c 8)" = mark0000 ]
PROBE
    chmod +x "$work/bin/fs.ntfs"
    {
        printf 'tool\tfixture\texit\tstdin\targv...\n'
        printf 'fs.ntfs\tntfs.img\t0\t-\tmark-probe\n'
        printf 'fs.ntfs\tntfs.img\t0\t-\tmark-probe\n'
        printf 'fs.ntfs\tntfs.img\t0\tpayload.bin\tmark-probe\n'
    } > "$work/matrix.tsv"
    before="$(sha256sum "$dir/ntfs.img" | cut -d' ' -f1)"
    PATH="$work/bin:$PATH" bash "$ROOT/scripts/cli-capability-matrix.sh" --run-all "$work/matrix.tsv" "$dir" \
        || fail 'executor did not give every operation a fresh copy'
    [ "$(sha256sum "$dir/ntfs.img" | cut -d' ' -f1)" = "$before" ] || fail 'executor changed the source fixture'
    [ "$fails" = 0 ] || return 1
    echo 'ntfs-capability-fixture: three overwrites each saw a fresh copy; source unchanged'
}

[ "$#" = 2 ] || usage
case "$1" in
    --dest) require_builders || exit 1; build "$2" ;;
    --check) require_builders || exit 1; check "$2" ;;
    *) usage ;;
esac
