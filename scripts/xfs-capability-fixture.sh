#!/usr/bin/env bash
# shellcheck disable=SC2015 # each && chain is the check; its || arm reports it
# Build and independently check the xfs capability seed (#491, part of #402).
#
#   --dest NEW_DIR   build NEW_DIR/xfs.img and NEW_DIR/payload.bin with
#                    xfsprogs and the kernel only, then verify them with
#                    xfs_repair -n, xfs_db and a read-only kernel mount
#   --check DIR      prove the capability executor gives every operation a
#                    fresh copy of DIR/xfs.img, using an xfs_db probe tool
#
# The seed is formatted and populated by mkfs.xfs from a protofile, and the
# hard link and the xattr, which a protofile cannot express, are added
# through a kernel loop mount; never by this constellation's writers. It is
# read back by xfs_repair -n and xfs_db from the unmounted image and by the
# kernel read-only, never by our readers. All of them run at arm's length as
# command-line tools; nothing is linked or copied. A missing builder fails
# naming the package that supplies it; nothing is skipped.
set -uo pipefail
# Builtins only until the builders are found: the refusal guard runs this
# with a PATH that holds none of them.
here="${BASH_SOURCE[0]%/*}"
[ "$here" = "${BASH_SOURCE[0]}" ] && here=.
ROOT="$(cd "$here/.." && pwd)"
usage() {
    echo 'usage: scripts/xfs-capability-fixture.sh --dest NEW_DIR | --check DIR' >&2
    exit 2
}
fails=0
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

require_builders() {
    local tool missing=0
    for tool in mkfs.xfs xfs_db xfs_repair setfattr getfattr mount umount truncate sha256sum cmp mktemp; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            case "$tool" in
                mkfs.xfs|xfs_db|xfs_repair)
                    echo "xfs-capability-fixture: missing $tool; install xfsprogs (apt-get install xfsprogs)" >&2 ;;
                setfattr|getfattr)
                    echo "xfs-capability-fixture: missing $tool; install attr (apt-get install attr)" >&2 ;;
                mount|umount)
                    echo "xfs-capability-fixture: missing $tool; install mount (apt-get install mount)" >&2 ;;
                *)
                    echo "xfs-capability-fixture: missing $tool; install coreutils" >&2 ;;
            esac
            missing=1
        fi
    done
    [ "$missing" = 0 ]
}

# The loop mount needs root; CI runs as a user with passwordless sudo.
as_root() {
    if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi
}

# The seed's shape. Every capability verb gets a valid operand:
#   /data.bin           8 KiB regular file: stat, write --at, truncate, rm,
#                       and the xattr user.capability = seed
#   /dir/file.txt       nonempty directory: ls -R, rm of a child, mv into
#   /empty              empty directory: rmdir, mkdir --parents below it
#   /link-target.txt    hard-link source, already linked as /hardlink.txt
#   /symlink            symbolic link to data.bin
#   /mv-src.txt         mv source
#   /replace-dst.txt    existing mv/replace destination
#   payload.bin         4 KiB stdin payload for write rows
# XFS has no named data streams, so stream verbs have no operand.
build() {
    local dest="$1" tree mnt out i
    [ ! -e "$dest" ] || { echo "xfs-capability-fixture: $dest exists; give a new directory" >&2; return 1; }
    mkdir -p "$dest" || return 1
    tree="$(mktemp -d)" || return 1
    mnt="$(mktemp -d)" || return 1
    # shellcheck disable=SC2064
    trap "as_root umount '$mnt' 2>/dev/null; rm -rf '$tree' '$mnt'" EXIT
    mkdir "$tree/dir"
    for i in $(seq 0 1023); do printf 'data%04d' "$i"; done > "$tree/data.bin"
    printf 'nonempty directory child\n' > "$tree/dir/file.txt"
    printf 'hard link target\n' > "$tree/link-target.txt"
    printf 'move source\n' > "$tree/mv-src.txt"
    printf 'replace destination\n' > "$tree/replace-dst.txt"
    for i in $(seq 0 511); do printf 'pay%05d' "$i"; done > "$dest/payload.bin"
    sha256sum "$tree/data.bin" | cut -d' ' -f1 > "$dest/data.bin.sha256"

    # mkfs.xfs(8) protofile: a boot-image line and a size line it ignores,
    # the root directory, then one entry per line; '$' closes a directory.
    cat > "$tree/proto" <<PROTO
/dev/null
0 0
d--755 0 0
data.bin ---644 0 0 $tree/data.bin
dir d--755 0 0
file.txt ---644 0 0 $tree/dir/file.txt
\$
empty d--755 0 0
\$
link-target.txt ---644 0 0 $tree/link-target.txt
symlink l--777 0 0 data.bin
mv-src.txt ---644 0 0 $tree/mv-src.txt
replace-dst.txt ---644 0 0 $tree/replace-dst.txt
\$
PROTO

    # mkfs.xfs refuses a filesystem below 300 MiB; the file is sparse.
    truncate -s 320M "$dest/xfs.img" || return 1
    out="$(mkfs.xfs -q -f -L capability -p "$tree/proto" "$dest/xfs.img" 2>&1)" \
        || { printf '%s\n' "$out" >&2; echo 'xfs-capability-fixture: mkfs.xfs failed' >&2; return 1; }
    out="$(as_root mount -t xfs -o loop "$dest/xfs.img" "$mnt" 2>&1)" \
        || { printf '%s\n' "$out" >&2; echo 'xfs-capability-fixture: loop mount failed' >&2; return 1; }
    as_root ln "$mnt/link-target.txt" "$mnt/hardlink.txt" \
        && as_root setfattr -n user.capability -v seed "$mnt/data.bin" \
        || { as_root umount "$mnt"; echo 'xfs-capability-fixture: populating the seed failed' >&2; return 1; }
    as_root umount "$mnt" || { echo 'xfs-capability-fixture: unmount failed' >&2; return 1; }
    verify "$dest" "$mnt"
}

# The names xfs_db lists in one directory of the unmounted image; the name
# is the last field, before any "(good)" verdict.
db_names() {
    xfs_db -r -f -c "ls $2" "$1" 2>/dev/null \
        | awk '{ n = $NF; if (n ~ /^\(.*\)$/) n = $(NF - 1); print n }'
}

# Read the seed back through xfsprogs and the kernel, not our drivers.
verify() {
    local dest="$1" mnt="$2" img="$1/xfs.img" root want inode_a inode_b out
    xfs_repair -n -f "$img" >/dev/null 2>&1 || fail 'xfs_repair -n finds the seed inconsistent'
    root="$(db_names "$img" /)"
    for want in data.bin dir empty link-target.txt hardlink.txt symlink mv-src.txt replace-dst.txt; do
        printf '%s\n' "$root" | grep -qxF -- "$want" || fail "xfs_db lists no /$want"
    done
    db_names "$img" /dir | grep -qxF file.txt || fail '/dir is not nonempty'
    db_names "$img" /empty | grep -qxF .. \
        && ! db_names "$img" /empty | grep -qvxF -e . -e .. || fail '/empty is not an empty directory'
    # Two names on one inode with a link count of 2 is a hard link.
    inode_a="$(xfs_db -r -f -c 'ls -i /link-target.txt' "$img" 2>/dev/null)"
    inode_b="$(xfs_db -r -f -c 'ls -i /hardlink.txt' "$img" 2>/dev/null)"
    [ -n "$inode_a" ] && [ "$inode_a" = "$inode_b" ] \
        && xfs_db -r -f -c 'path /link-target.txt' -c 'print core.nlinkv2' "$img" 2>/dev/null | grep -q '= 2$' \
        || fail '/hardlink.txt is not a hard link of /link-target.txt'
    xfs_db -r -f -c 'path /symlink' -c print "$img" 2>/dev/null | grep -q '"data\.bin"' \
        || fail 'xfs_db finds no symlink to data.bin'
    out="$(xfs_db -r -f -c 'path /data.bin' -c print "$img" 2>/dev/null)"
    printf '%s\n' "$out" | grep -q 'name = "capability"' && printf '%s\n' "$out" | grep -q 'value = "seed"' \
        || fail 'xfs_db finds no capability xattr holding seed on /data.bin'
    # The kernel, read-only, confirms the bytes and the namespaces.
    if out="$(as_root mount -t xfs -o loop,ro "$img" "$mnt" 2>&1)"; then
        [ "$(as_root sha256sum "$mnt/data.bin" | cut -d' ' -f1)" = "$(cat "$dest/data.bin.sha256")" ] \
            || fail 'the kernel reads /data.bin with the wrong bytes'
        [ "$(as_root readlink "$mnt/symlink")" = data.bin ] || fail 'the kernel reads /symlink as not data.bin'
        [ "$(as_root getfattr --only-values -n user.capability "$mnt/data.bin" 2>/dev/null)" = seed ] \
            || fail 'the kernel finds no user.capability = seed on /data.bin'
        [ "$(as_root stat -c %h "$mnt/hardlink.txt")" = 2 ] || fail 'the kernel counts /hardlink.txt links as not 2'
        as_root umount "$mnt" || fail 'read-only unmount failed'
    else
        printf '%s\n' "$out" >&2
        fail 'the kernel cannot mount the seed read-only'
    fi
    [ "$(wc -c < "$dest/payload.bin")" -eq 4096 ] || fail 'payload.bin is not 4096 bytes'
    [ "$fails" = 0 ] || return 1
    echo "xfs-capability-fixture: seed verified by xfs_repair -n, xfs_db and the kernel in $dest"
}

# Every row relabels its image. If the executor reused a copy, or handed the
# driver the source fixture, a later row would find the label changed.
check() {
    local dir="$1" work before
    [ -f "$dir/xfs.img" ] || { echo "xfs-capability-fixture: no $dir/xfs.img; build it with --dest" >&2; return 1; }
    work="$(mktemp -d)" || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT
    mkdir "$work/bin"
    cat > "$work/bin/fs.xfs" <<'PROBE'
#!/usr/bin/env bash
# Probe, not a driver: xfs_db relabels the image only if it is still the seed's.
[ "${2:-}" = label-probe ] || exit 2
xfs_db -r -f -c label "$1" 2>/dev/null | grep -q '"capability"' || { echo 'stale copy: label already changed' >&2; exit 1; }
xfs_db -x -f -c 'label marked' "$1" >/dev/null 2>&1 || exit 1
xfs_db -r -f -c label "$1" 2>/dev/null | grep -q '"marked"'
PROBE
    chmod +x "$work/bin/fs.xfs"
    {
        printf 'tool\tfixture\texit\tstdin\targv...\n'
        printf 'fs.xfs\txfs.img\t0\t-\tlabel-probe\n'
        printf 'fs.xfs\txfs.img\t0\t-\tlabel-probe\n'
        printf 'fs.xfs\txfs.img\t0\tpayload.bin\tlabel-probe\n'
    } > "$work/matrix.tsv"
    before="$(sha256sum "$dir/xfs.img" | cut -d' ' -f1)"
    PATH="$work/bin:$PATH" bash "$ROOT/scripts/cli-capability-matrix.sh" --run-all "$work/matrix.tsv" "$dir" \
        || fail 'executor did not give every operation a fresh copy'
    [ "$(sha256sum "$dir/xfs.img" | cut -d' ' -f1)" = "$before" ] || fail 'executor changed the source fixture'
    [ "$fails" = 0 ] || return 1
    echo 'xfs-capability-fixture: three relabels each saw a fresh copy; source unchanged'
}

[ "$#" = 2 ] || usage
case "$1" in
    --dest) require_builders || exit 1; build "$2" ;;
    --check) require_builders || exit 1; check "$2" ;;
    *) usage ;;
esac
