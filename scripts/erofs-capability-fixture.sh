#!/usr/bin/env bash
# shellcheck disable=SC2015 # each && chain is the check; its || arm reports it
# Build and independently check the erofs capability seed (#494, part of #402).
#
#   --dest NEW_DIR   build NEW_DIR/erofs.img and NEW_DIR/payload.bin with
#                    erofs-utils only, then verify them with fsck.erofs and a
#                    read-only kernel mount
#   --check DIR      prove the capability executor gives every operation a
#                    fresh copy of DIR/erofs.img, using a marking probe
#
# The seed is built by mkfs.erofs from a staged tree that already holds its
# hard link, symlink and xattr, so nothing writes the image after
# mkfs.erofs; never this constellation's writers. It is checked by
# fsck.erofs and read back by the kernel read-only, never by our readers.
# All of them run at arm's length as command-line tools; nothing is linked
# or copied. A missing builder fails naming the package that supplies it;
# nothing is skipped.
set -uo pipefail
# Builtins only until the builders are found: the refusal guard runs this
# with a PATH that holds none of them.
here="${BASH_SOURCE[0]%/*}"
[ "$here" = "${BASH_SOURCE[0]}" ] && here=.
ROOT="$(cd "$here/.." && pwd)"
usage() {
    echo 'usage: scripts/erofs-capability-fixture.sh --dest NEW_DIR | --check DIR' >&2
    exit 2
}
fails=0
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

require_builders() {
    local tool missing=0
    for tool in mkfs.erofs fsck.erofs setfattr getfattr mount umount sha256sum cmp dd mktemp; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            case "$tool" in
                mkfs.erofs|fsck.erofs)
                    echo "erofs-capability-fixture: missing $tool; install erofs-utils (apt-get install erofs-utils)" >&2 ;;
                setfattr|getfattr)
                    echo "erofs-capability-fixture: missing $tool; install attr (apt-get install attr)" >&2 ;;
                mount|umount)
                    echo "erofs-capability-fixture: missing $tool; install mount (apt-get install mount)" >&2 ;;
                *)
                    echo "erofs-capability-fixture: missing $tool; install coreutils" >&2 ;;
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

# The seed's shape. Every capability verb gets a valid operand, even though
# a read-only format refuses every change:
#   /data.bin           8 KiB regular file: stat, write --at, truncate, rm,
#                       and the xattr user.capability = seed
#   /dir/file.txt       nonempty directory: ls -R, rm of a child, mv into
#   /empty              empty directory: rmdir, mkdir --parents below it
#   /link-target.txt    hard-link source, already linked as /hardlink.txt
#   /symlink            symbolic link to data.bin
#   /mv-src.txt         mv source
#   /replace-dst.txt    existing mv/replace destination
#   payload.bin         4 KiB stdin payload for write rows
# EROFS has no named data streams, so stream verbs have no operand.
build() {
    local dest="$1" tree mnt out i
    [ ! -e "$dest" ] || { echo "erofs-capability-fixture: $dest exists; give a new directory" >&2; return 1; }
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
    ln "$tree/root/link-target.txt" "$tree/root/hardlink.txt" \
        && ln -s data.bin "$tree/root/symlink" \
        && setfattr -n user.capability -v seed "$tree/root/data.bin" \
        || { echo 'erofs-capability-fixture: staging the tree failed (does its filesystem take user xattrs?)' >&2; return 1; }
    for i in $(seq 0 511); do printf 'pay%05d' "$i"; done > "$dest/payload.bin"
    sha256sum "$tree/root/data.bin" | cut -d' ' -f1 > "$dest/data.bin.sha256"

    # mkfs.erofs keeps the staged inodes' hard links and copies their xattrs.
    out="$(mkfs.erofs "$dest/erofs.img" "$tree/root" 2>&1)" \
        || { printf '%s\n' "$out" >&2; echo 'erofs-capability-fixture: mkfs.erofs failed' >&2; return 1; }
    verify "$dest" "$mnt"
}

# Read the seed back through erofs-utils and the kernel, not our drivers.
verify() {
    local dest="$1" mnt="$2" img="$1/erofs.img" listed inode_a inode_b out
    fsck.erofs "$img" >/dev/null 2>&1 || fail 'fsck.erofs finds the seed inconsistent'
    # The kernel, read-only, confirms the names, bytes, links and xattr.
    if out="$(as_root mount -t erofs -o loop,ro "$img" "$mnt" 2>&1)"; then
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
    echo "erofs-capability-fixture: seed verified by fsck.erofs and the kernel in $dest"
}

# EROFS cannot be changed in place, so the probe marks the image's first
# block, which the format leaves unused before its superblock at byte 1024,
# and only while the copy still hashes as the seed. If the executor reused a
# copy, or handed the driver the source fixture, a later row would find it
# marked.
check() {
    local dir="$1" work before
    [ -f "$dir/erofs.img" ] || { echo "erofs-capability-fixture: no $dir/erofs.img; build it with --dest" >&2; return 1; }
    work="$(mktemp -d)" || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT
    mkdir "$work/bin"
    before="$(sha256sum "$dir/erofs.img" | cut -d' ' -f1)"
    cat > "$work/bin/fs.erofs" <<PROBE
#!/usr/bin/env bash
# Probe, not a driver: it marks the copy only if it is still the seed.
[ "\${2:-}" = mark-probe ] || exit 2
fsck.erofs "\$1" >/dev/null 2>&1 || { echo 'the copy is not a sound erofs image' >&2; exit 1; }
[ "\$(sha256sum "\$1" | cut -d' ' -f1)" = '$before' ] || { echo 'stale copy: already marked' >&2; exit 1; }
printf marked | dd of="\$1" bs=1 seek=0 conv=notrunc status=none || exit 1
[ "\$(sha256sum "\$1" | cut -d' ' -f1)" != '$before' ]
PROBE
    chmod +x "$work/bin/fs.erofs"
    {
        printf 'tool\tfixture\texit\tstdin\targv...\n'
        printf 'fs.erofs\terofs.img\t0\t-\tmark-probe\n'
        printf 'fs.erofs\terofs.img\t0\t-\tmark-probe\n'
        printf 'fs.erofs\terofs.img\t0\tpayload.bin\tmark-probe\n'
    } > "$work/matrix.tsv"
    PATH="$work/bin:$PATH" bash "$ROOT/scripts/cli-capability-matrix.sh" --run-all "$work/matrix.tsv" "$dir" \
        || fail 'executor did not give every operation a fresh copy'
    [ "$(sha256sum "$dir/erofs.img" | cut -d' ' -f1)" = "$before" ] || fail 'executor changed the source fixture'
    [ "$fails" = 0 ] || return 1
    echo 'erofs-capability-fixture: three marks each saw a fresh copy; source unchanged'
}

[ "$#" = 2 ] || usage
case "$1" in
    --dest) require_builders || exit 1; build "$2" ;;
    --check) require_builders || exit 1; check "$2" ;;
    *) usage ;;
esac
