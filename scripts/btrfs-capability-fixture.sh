#!/usr/bin/env bash
# shellcheck disable=SC2015 # each && chain is the check; its || arm reports it
# Build and independently check the btrfs capability seed (#492, part of #402).
#
#   --dest NEW_DIR   build NEW_DIR/btrfs.img and NEW_DIR/payload.bin with
#                    btrfs-progs and the kernel only, then verify them with
#                    btrfs check --readonly, btrfs inspect-internal dump-tree
#                    and a read-only kernel mount
#   --check DIR      prove the capability executor gives every operation a
#                    fresh copy of DIR/btrfs.img, using a btrfs label probe
#
# The seed is formatted and populated by mkfs.btrfs --rootdir from a staged
# tree, and the hard link and the xattr are added through a kernel loop
# mount; never by this constellation's writers. It is read back by btrfs
# check and dump-tree from the unmounted image and by the kernel read-only,
# never by our readers. All of them run at arm's length as command-line
# tools; nothing is linked or copied. A missing builder fails naming the
# package that supplies it; nothing is skipped.
set -uo pipefail
# Builtins only until the builders are found: the refusal guard runs this
# with a PATH that holds none of them.
here="${BASH_SOURCE[0]%/*}"
[ "$here" = "${BASH_SOURCE[0]}" ] && here=.
ROOT="$(cd "$here/.." && pwd)"
usage() {
    echo 'usage: scripts/btrfs-capability-fixture.sh --dest NEW_DIR | --check DIR' >&2
    exit 2
}
fails=0
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

require_builders() {
    local tool missing=0
    for tool in mkfs.btrfs btrfs setfattr getfattr mount umount truncate sha256sum cmp mktemp; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            case "$tool" in
                mkfs.btrfs|btrfs)
                    echo "btrfs-capability-fixture: missing $tool; install btrfs-progs (apt-get install btrfs-progs)" >&2 ;;
                setfattr|getfattr)
                    echo "btrfs-capability-fixture: missing $tool; install attr (apt-get install attr)" >&2 ;;
                mount|umount)
                    echo "btrfs-capability-fixture: missing $tool; install mount (apt-get install mount)" >&2 ;;
                *)
                    echo "btrfs-capability-fixture: missing $tool; install coreutils" >&2 ;;
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
# Btrfs has no named data streams, so stream verbs have no operand.
build() {
    local dest="$1" tree mnt out i
    [ ! -e "$dest" ] || { echo "btrfs-capability-fixture: $dest exists; give a new directory" >&2; return 1; }
    mkdir -p "$dest" || return 1
    tree="$(mktemp -d)" || return 1
    mnt="$(mktemp -d)" || return 1
    # shellcheck disable=SC2064
    trap "as_root umount '$mnt' 2>/dev/null; rm -rf '$tree' '$mnt'" EXIT
    mkdir "$tree/root" "$tree/root/dir" "$tree/root/empty"
    for i in $(seq 0 1023); do printf 'data%04d' "$i"; done > "$tree/root/data.bin"
    printf 'nonempty directory child\n' > "$tree/root/dir/file.txt"
    printf 'hard link target\n' > "$tree/root/link-target.txt"
    printf 'move source\n' > "$tree/root/mv-src.txt"
    printf 'replace destination\n' > "$tree/root/replace-dst.txt"
    ln -s data.bin "$tree/root/symlink"
    for i in $(seq 0 511); do printf 'pay%05d' "$i"; done > "$dest/payload.bin"
    sha256sum "$tree/root/data.bin" | cut -d' ' -f1 > "$dest/data.bin.sha256"

    # mkfs.btrfs keeps an existing image file's size; the file is sparse.
    truncate -s 256M "$dest/btrfs.img" || return 1
    out="$(mkfs.btrfs -q -f -L capability --rootdir "$tree/root" "$dest/btrfs.img" 2>&1)" \
        || { printf '%s\n' "$out" >&2; echo 'btrfs-capability-fixture: mkfs.btrfs failed' >&2; return 1; }
    out="$(as_root mount -t btrfs -o loop "$dest/btrfs.img" "$mnt" 2>&1)" \
        || { printf '%s\n' "$out" >&2; echo 'btrfs-capability-fixture: loop mount failed' >&2; return 1; }
    as_root ln "$mnt/link-target.txt" "$mnt/hardlink.txt" \
        && as_root setfattr -n user.capability -v seed "$mnt/data.bin" \
        || { as_root umount "$mnt"; echo 'btrfs-capability-fixture: populating the seed failed' >&2; return 1; }
    as_root umount "$mnt" || { echo 'btrfs-capability-fixture: unmount failed' >&2; return 1; }
    verify "$dest" "$mnt"
}

# Read the seed back through btrfs-progs and the kernel, not our drivers.
verify() {
    local dest="$1" mnt="$2" img="$1/btrfs.img" names want listed inode_a inode_b out
    btrfs check --readonly "$img" >/dev/null 2>&1 || fail 'btrfs check --readonly finds the seed inconsistent'
    # The default subvolume's tree (id 5), as btrfs-progs prints it: each
    # directory entry, inode back-reference and xattr item ends in `name: X`.
    names="$(btrfs inspect-internal dump-tree -t 5 "$img" 2>/dev/null | sed -n 's/^.*[[:space:]]name: //p')"
    [ -n "$names" ] || fail 'btrfs inspect-internal dump-tree names nothing in the seed'
    for want in data.bin dir file.txt empty link-target.txt hardlink.txt symlink mv-src.txt replace-dst.txt \
        user.capability; do
        printf '%s\n' "$names" | grep -qxF -- "$want" || fail "dump-tree names no $want"
    done
    # The kernel, read-only, confirms the names, bytes, links and xattr.
    if out="$(as_root mount -t btrfs -o loop,ro "$img" "$mnt" 2>&1)"; then
        listed="$(as_root ls -A "$mnt" | LC_ALL=C sort | tr '\n' ' ')"
        [ "$listed" = 'data.bin dir empty hardlink.txt link-target.txt mv-src.txt replace-dst.txt symlink ' ] \
            || fail "the kernel lists the root as: $listed"
        [ "$(as_root ls -A "$mnt/dir")" = file.txt ] || fail '/dir does not hold exactly file.txt'
        [ -z "$(as_root ls -A "$mnt/empty")" ] && as_root test -d "$mnt/empty" || fail '/empty is not an empty directory'
        [ "$(as_root sha256sum "$mnt/data.bin" | cut -d' ' -f1)" = "$(cat "$dest/data.bin.sha256")" ] \
            || fail 'the kernel reads /data.bin with the wrong bytes'
        [ "$(as_root readlink "$mnt/symlink")" = data.bin ] || fail 'the kernel reads /symlink as not data.bin'
        [ "$(as_root getfattr --only-values -n user.capability "$mnt/data.bin" 2>/dev/null)" = seed ] \
            || fail 'the kernel finds no user.capability = seed on /data.bin'
        inode_a="$(as_root stat -c %i "$mnt/link-target.txt")"
        inode_b="$(as_root stat -c %i "$mnt/hardlink.txt")"
        [ -n "$inode_a" ] && [ "$inode_a" = "$inode_b" ] && [ "$(as_root stat -c %h "$mnt/hardlink.txt")" = 2 ] \
            || fail '/hardlink.txt is not a hard link of /link-target.txt with a link count of 2'
        as_root umount "$mnt" || fail 'read-only unmount failed'
    else
        printf '%s\n' "$out" >&2
        fail 'the kernel cannot mount the seed read-only'
    fi
    [ "$(wc -c < "$dest/payload.bin")" -eq 4096 ] || fail 'payload.bin is not 4096 bytes'
    [ "$fails" = 0 ] || return 1
    echo "btrfs-capability-fixture: seed verified by btrfs check, dump-tree and the kernel in $dest"
}

# Every row relabels its image. If the executor reused a copy, or handed the
# driver the source fixture, a later row would find the label changed.
check() {
    local dir="$1" work before
    [ -f "$dir/btrfs.img" ] || { echo "btrfs-capability-fixture: no $dir/btrfs.img; build it with --dest" >&2; return 1; }
    work="$(mktemp -d)" || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT
    mkdir "$work/bin"
    cat > "$work/bin/fs.btrfs" <<'PROBE'
#!/usr/bin/env bash
# Probe, not a driver: btrfs-progs relabels the unmounted image only if it
# is still the seed's.
[ "${2:-}" = label-probe ] || exit 2
[ "$(btrfs filesystem label "$1" 2>/dev/null)" = capability ] || { echo 'stale copy: label already changed' >&2; exit 1; }
btrfs filesystem label "$1" marked >/dev/null 2>&1 || exit 1
[ "$(btrfs filesystem label "$1" 2>/dev/null)" = marked ]
PROBE
    chmod +x "$work/bin/fs.btrfs"
    {
        printf 'tool\tfixture\texit\tstdin\targv...\n'
        printf 'fs.btrfs\tbtrfs.img\t0\t-\tlabel-probe\n'
        printf 'fs.btrfs\tbtrfs.img\t0\t-\tlabel-probe\n'
        printf 'fs.btrfs\tbtrfs.img\t0\tpayload.bin\tlabel-probe\n'
    } > "$work/matrix.tsv"
    before="$(sha256sum "$dir/btrfs.img" | cut -d' ' -f1)"
    PATH="$work/bin:$PATH" bash "$ROOT/scripts/cli-capability-matrix.sh" --run-all "$work/matrix.tsv" "$dir" \
        || fail 'executor did not give every operation a fresh copy'
    [ "$(sha256sum "$dir/btrfs.img" | cut -d' ' -f1)" = "$before" ] || fail 'executor changed the source fixture'
    [ "$fails" = 0 ] || return 1
    echo 'btrfs-capability-fixture: three relabels each saw a fresh copy; source unchanged'
}

[ "$#" = 2 ] || usage
case "$1" in
    --dest) require_builders || exit 1; build "$2" ;;
    --check) require_builders || exit 1; check "$2" ;;
    *) usage ;;
esac
