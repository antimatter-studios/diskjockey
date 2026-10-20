#!/usr/bin/env bash
# Build and independently check the ext4 capability seed (#489, part of #402).
#
#   --dest NEW_DIR   build NEW_DIR/ext4.img and NEW_DIR/payload.bin with
#                    e2fsprogs only, then verify them with e2fsck and debugfs
#   --check DIR      prove the capability executor gives every operation a
#                    fresh copy of DIR/ext4.img, using a debugfs probe tool
#
# The seed is written by mke2fs -d and debugfs, never by this constellation's
# writers, and read back by e2fsck and debugfs, never by our readers. Both run
# at arm's length as command-line tools. A missing builder fails naming the
# package that supplies it; nothing is skipped.
set -uo pipefail
# Builtins only until the builders are found: the refusal guard runs this
# with a PATH that holds none of them.
here="${BASH_SOURCE[0]%/*}"
[ "$here" = "${BASH_SOURCE[0]}" ] && here=.
ROOT="$(cd "$here/.." && pwd)"
usage() {
    echo 'usage: scripts/ext4-capability-fixture.sh --dest NEW_DIR | --check DIR' >&2
    exit 2
}
# debugfs output is parsed, so it must never go through a pager.
export DEBUGFS_PAGER=__none__ PAGER=cat
fails=0
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

require_builders() {
    local tool missing=0
    for tool in mke2fs debugfs e2fsck sha256sum cmp mktemp; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            case "$tool" in
                mke2fs|debugfs|e2fsck)
                    echo "ext4-capability-fixture: missing $tool; install e2fsprogs (apt-get install e2fsprogs)" >&2 ;;
                *)
                    echo "ext4-capability-fixture: missing $tool; install coreutils" >&2 ;;
            esac
            missing=1
        fi
    done
    [ "$missing" = 0 ]
}

# The seed's shape. Every capability verb gets a valid operand:
#   /data.bin           8 KiB regular file: stat, write --at, truncate, rm,
#                       xattr (user.capability = seed)
#   /dir/file.txt       nonempty directory: ls -R, rm of a child, mv into
#   /empty              empty directory: rmdir, mkdir --parents below it
#   /link-target.txt    hard-link source, already linked as /hardlink.txt
#   /symlink            symbolic link to data.bin
#   /mv-src.txt         mv source
#   /replace-dst.txt    existing mv/replace destination
#   payload.bin         4 KiB stdin payload for write rows
# ext4 has no named data streams, so stream verbs have no operand and are
# expected to be refused (exit 3).
build() {
    local dest="$1" tree i
    [ ! -e "$dest" ] || { echo "ext4-capability-fixture: $dest exists; give a new directory" >&2; return 1; }
    mkdir -p "$dest" || return 1
    tree="$(mktemp -d)" || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$tree'" EXIT
    mkdir "$tree/dir" "$tree/empty"
    for i in $(seq 0 1023); do printf 'data%04d' "$i"; done > "$tree/data.bin"
    printf 'nonempty directory child\n' > "$tree/dir/file.txt"
    printf 'hard link target\n' > "$tree/link-target.txt"
    ln "$tree/link-target.txt" "$tree/hardlink.txt"
    ln -s data.bin "$tree/symlink"
    printf 'move source\n' > "$tree/mv-src.txt"
    printf 'replace destination\n' > "$tree/replace-dst.txt"
    for i in $(seq 0 511); do printf 'pay%05d' "$i"; done > "$dest/payload.bin"

    # 256-byte inodes keep the xattr in-inode; the fixed UUID keeps reruns
    # comparable. mke2fs -d copies the tree, hard link included.
    mke2fs -q -F -t ext4 -b 4096 -I 256 -L capability \
        -U 4c0e1a5e-89a1-4b8e-9d5c-000000000489 -d "$tree" "$dest/ext4.img" 32M \
        || { echo 'ext4-capability-fixture: mke2fs failed' >&2; return 1; }
    debugfs -w -R 'ea_set /data.bin user.capability seed' "$dest/ext4.img" >/dev/null 2>&1 \
        || { echo 'ext4-capability-fixture: debugfs ea_set failed' >&2; return 1; }
    sha256sum "$tree/data.bin" | cut -d' ' -f1 > "$dest/data.bin.sha256"
    verify "$dest"
}

dfs() { debugfs -R "$1" "$2" 2>/dev/null; }

# Read the seed back through e2fsprogs, not through our drivers.
verify() {
    local dest="$1" img="$1/ext4.img" root inode_a inode_b want
    e2fsck -fn "$img" >/dev/null 2>&1 || fail 'e2fsck -fn reports the seed is not clean'
    root="$(dfs 'ls -p /' "$img")"
    for want in data.bin dir empty link-target.txt hardlink.txt symlink mv-src.txt replace-dst.txt; do
        printf '%s\n' "$root" | grep -q "/$want/" || fail "debugfs lists no /$want"
    done
    [ "$(dfs 'cat /data.bin' "$img" | sha256sum | cut -d' ' -f1)" = "$(cat "$dest/data.bin.sha256")" ] \
        || fail 'debugfs reads /data.bin with the wrong bytes'
    dfs 'ls -p /dir' "$img" | grep -q '/file.txt/' || fail '/dir is not nonempty'
    # ls -p prints /inode/mode/uid/gid/name/size/ per entry.
    if [ "$(dfs 'ls -p /empty' "$img" | awk -F/ 'NF > 6 && $6 != "." && $6 != ".."' | wc -l | tr -d ' ')" != 0 ] \
        || ! dfs 'ls -p /empty' "$img" | awk -F/ '$6 == ".."' | grep -q .; then
        fail '/empty is not an empty directory'
    fi
    inode_a="$(dfs 'stat /link-target.txt' "$img" | sed -n 's/^Inode: \([0-9]*\).*/\1/p')"
    inode_b="$(dfs 'stat /hardlink.txt' "$img" | sed -n 's/^Inode: \([0-9]*\).*/\1/p')"
    [ -n "$inode_a" ] && [ "$inode_a" = "$inode_b" ] || fail '/hardlink.txt is not a hard link of /link-target.txt'
    dfs 'stat /link-target.txt' "$img" | grep -q 'Links: 2' || fail '/link-target.txt link count is not 2'
    dfs 'stat /symlink' "$img" | grep -q 'Fast link dest: "data.bin"' || fail '/symlink does not point at data.bin'
    dfs 'ea_get /data.bin user.capability' "$img" | grep -q 'seed' || fail '/data.bin has no user.capability xattr'
    [ "$(wc -c < "$dest/payload.bin")" -eq 4096 ] || fail 'payload.bin is not 4096 bytes'
    [ "$fails" = 0 ] || return 1
    echo "ext4-capability-fixture: seed verified by e2fsck and debugfs in $dest"
}

# Every row removes /data.bin from its image. If the executor reused a copy,
# or handed the driver the source fixture, a later row would find it gone.
check() {
    local dir="$1" work before
    [ -f "$dir/ext4.img" ] || { echo "ext4-capability-fixture: no $dir/ext4.img; build it with --dest" >&2; return 1; }
    work="$(mktemp -d)" || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT
    mkdir "$work/bin"
    cat > "$work/bin/fs.ext4" <<'PROBE'
#!/usr/bin/env bash
# Probe, not a driver: debugfs removes /data.bin only if it is still there.
[ "${2:-}" = rm-probe ] || exit 2
debugfs -R 'stat /data.bin' "$1" 2>/dev/null | grep -q '^Inode:' || { echo 'stale copy: /data.bin already gone' >&2; exit 1; }
debugfs -w -R 'rm /data.bin' "$1" >/dev/null 2>&1 || exit 1
! debugfs -R 'stat /data.bin' "$1" 2>/dev/null | grep -q '^Inode:'
PROBE
    chmod +x "$work/bin/fs.ext4"
    {
        printf 'tool\tfixture\texit\tstdin\targv...\n'
        printf 'fs.ext4\text4.img\t0\t-\trm-probe\n'
        printf 'fs.ext4\text4.img\t0\t-\trm-probe\n'
        printf 'fs.ext4\text4.img\t0\tpayload.bin\trm-probe\n'
    } > "$work/matrix.tsv"
    before="$(sha256sum "$dir/ext4.img" | cut -d' ' -f1)"
    PATH="$work/bin:$PATH" bash "$ROOT/scripts/cli-capability-matrix.sh" --run-all "$work/matrix.tsv" "$dir" \
        || fail 'executor did not give every operation a fresh copy'
    [ "$(sha256sum "$dir/ext4.img" | cut -d' ' -f1)" = "$before" ] || fail 'executor changed the source fixture'
    [ "$fails" = 0 ] || return 1
    echo 'ext4-capability-fixture: three removals each saw a fresh copy; source unchanged'
}

[ "$#" = 2 ] || usage
case "$1" in
    --dest) require_builders || exit 1; build "$2" ;;
    --check) require_builders || exit 1; check "$2" ;;
    *) usage ;;
esac
