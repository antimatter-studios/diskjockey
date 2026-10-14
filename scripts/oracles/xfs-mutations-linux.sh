#!/usr/bin/env bash
# The Linux half of scripts/test-xfs-mutations.sh: xfsprogs' own mkfs.xfs
# makes the image, and after the FSKit volume has changed it, xfs_repair -n,
# xfs_logprint, xfs_db and the kernel check it (diskjockey#322, #355).
#
# It runs as root INSIDE fs-linux-test-harness's VM, which installs xfsprogs,
# attr and acl (scripts/oracles/vm-setup.sh), loop-mounts the image and
# clears the kernel's message buffer; scripts/xfs-mutations-vm.sh starts it
# there with <dir> in the shared directory. Run it nowhere else.
#
# THE TOOLS WORK ON THE GUEST'S OWN DISK, never on the share. The share is a
# host directory behind 9p or virtiofs, not a disk: mmap and O_DIRECT opens
# of a file on it fail in ways that read as a verdict on the image. So the
# image is made, and copied in to be judged, under /var/tmp (not a tmpfs
# /tmp, which is sized from the guest's memory), and only the made image is
# copied back.
#
#   xfs-mutations-linux.sh create <dir>   # <dir>/xfs.img, populated
#   xfs-mutations-linux.sh verify <dir>   # <dir>/xfs.img against <dir>/expected/
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
[ $# -eq 2 ] || { echo 'usage: xfs-mutations-linux.sh create|verify <dir>' >&2; exit 2; }
action="$1"
work="$2"
image="$work/xfs.img"
expected="$work/expected"
# What xfs_db calls the volume's version and features when it is made; the
# FSKit volume must leave them as they are.
features="$work/features"
scratch="$(mktemp -d /var/tmp/xfs-mutations.XXXXXX)"
img="$scratch/xfs.img"
mnt="$scratch/mnt"
mkdir "$mnt"
cleanup() {
    umount "$mnt" 2>/dev/null || true
    rm -rf "$scratch"
}
trap cleanup EXIT
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
echo "xfs-mutations-linux: kernel $(uname -r), $(mkfs.xfs -V)"

case "$action" in
    create)
        mkdir -p "$expected"
        truncate -s 400M "$img"
        mkfs.xfs -q -f "$img"
        mount -o loop "$img" "$mnt"
        head -c 4096 /dev/zero | tr '\0' 'L' > "$mnt/data"
        echo doomed > "$mnt/doomed"
        mkdir "$mnt/emptydir" "$mnt/fulldir"
        echo keep > "$mnt/fulldir/keep"
        echo 'move me' > "$mnt/moveme"
        mkdir -p "$mnt/dirA/sub" "$mnt/dirB"
        echo deep > "$mnt/dirA/sub/f"
        echo old > "$mnt/victim"
        echo new > "$mnt/replacer"
        echo linked > "$mnt/linksrc"
        echo 'metadata oracle' > "$mnt/attrs"
        chown 1001:1001 "$mnt/attrs"
        echo protected > "$mnt/protected"
        setfattr -n user.dj -v original "$mnt/protected"
        setfacl -m u:1002:r-- "$mnt/protected"
        umount "$mnt"
        xfs_db -r -c version "$img" > "$features"
        cp --sparse=always "$img" "$image"
        # The host's other steps run unprivileged: they read the image, the
        # macOS job writes it, and the expected bytes land beside it.
        chmod -R a+rwX "$work"
        echo "xfs-mutations-linux: made $image ($(cat "$features"))"
        exit 0
        ;;
    verify) ;;
    *) echo 'usage: xfs-mutations-linux.sh create|verify <dir>' >&2; exit 2 ;;
esac

[ -f "$image" ] || { echo "FAIL: $image is missing" >&2; exit 1; }
[ -f "$expected/data" ] || { echo "FAIL: $expected/data is missing; run scripts/test-xfs-mutations.sh on the image first" >&2; exit 1; }
[ -f "$features" ] || { echo "FAIL: $features is missing; make the image with create" >&2; exit 1; }
cp --sparse=always "$image" "$img"
rc=0
report="$(xfs_repair -n "$img" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$report" | grep -qiE 'would|error|bad|corrupt'; then
    ok 'xfs_repair -n finds nothing, with no replay first'
else
    fail "xfs_repair -n (exit $rc):"; printf '%s\n' "$report"
fi
if [ "$(xfs_db -r -c version "$img")" = "$(cat "$features")" ]; then
    ok "xfs_db reads the version and features mkfs.xfs made: $(cat "$features")"
else
    fail "xfs_db reads $(xfs_db -r -c version "$img"), not $(cat "$features")"
fi
if xfs_logprint -t "$img" 2>&1 | grep -q 'state: <CLEAN>'; then
    ok 'xfs_logprint calls the log clean'
else
    fail 'the log is not clean'
fi

dmesg -C
mount -o loop,noatime "$img" "$mnt"
if cmp -s "$mnt/data" "$expected/data"; then ok '/data holds the bytes FSKit wrote'; else fail '/data differs'; fi
[ "$(stat -c %s "$mnt/data")" = 15000 ] && ok '/data is 15000 bytes' || fail "/data is $(stat -c %s "$mnt/data") bytes"
# Create and remove (#326).
[ "$(stat -c '%a %u %g %s' "$mnt/made.txt")" = '640 1001 1002 13' ] && ok 'made.txt: mode 640, owner 1001:1002, 13 bytes' || fail "made.txt: $(stat -c '%a %u %g %s' "$mnt/made.txt" 2>&1)"
[ "$(cat "$mnt/made.txt")" = 'made by FSKit' ] && ok 'made.txt holds what FSKit wrote' || fail 'made.txt contents'
[ "$(stat -c '%F %a %h' "$mnt/newdir")" = 'directory 750 2' ] && ok 'newdir: a directory, mode 750, 2 links' || fail "newdir: $(stat -c '%F %a %h' "$mnt/newdir" 2>&1)"
[ -f "$mnt/newdir/inner" ] && ok 'newdir/inner exists' || fail 'newdir/inner is missing'
[ ! -e "$mnt/doomed" ] && ok 'doomed is unlinked' || fail 'doomed is still there'
[ ! -e "$mnt/emptydir" ] && ok 'emptydir is removed' || fail 'emptydir is still there'
[ "$(cat "$mnt/fulldir/keep")" = keep ] && ok 'fulldir/keep survived the refused rmdir' || fail 'fulldir/keep changed'
# Rename and links (#327).
[ "$(cat "$mnt/renamed")" = 'move me' ] && [ ! -e "$mnt/moveme" ] && ok 'moveme is renamed within its directory' || fail 'moveme was not renamed'
[ "$(cat "$mnt/dirB/sub2/f")" = deep ] && [ ! -e "$mnt/dirA/sub" ] && ok 'dirA/sub moved to dirB/sub2 with what it holds' || fail 'dirA/sub did not move'
[ "$(stat -c %h "$mnt/dirA") $(stat -c %h "$mnt/dirB")" = '2 3' ] && ok 'the parents link counts follow the moved directory' || fail "parent links: $(stat -c %h "$mnt/dirA") $(stat -c %h "$mnt/dirB")"
[ "$(cat "$mnt/victim")" = new ] && [ ! -e "$mnt/replacer" ] && ok 'replacer replaced victim' || fail 'victim was not replaced'
[ "$(stat -c %i "$mnt/linksrc")" = "$(stat -c %i "$mnt/dirB/hard")" ] && [ "$(stat -c %h "$mnt/linksrc")" = 2 ] && ok 'dirB/hard is a second name for linksrc, 2 links' || fail 'the hard link is wrong'
[ ! -e "$mnt/sym" ] && ok 'no symlink was made' || fail 'a symlink appeared'
# Attributes and extended attributes (#328).
[ "$(stat -c '%a %u %g %X %Y' "$mnt/attrs")" = '600 1002 1004 -1 1800000000' ] && ok 'attrs: mode 600, owner 1002:1004, atime -1, mtime 1800000000' || fail "attrs: $(stat -c '%a %u %g %X %Y' "$mnt/attrs")"
TZ=UTC stat -c '%x' "$mnt/attrs" | grep -qF '1969-12-31 23:59:59.123456789 +0000' && ok 'attrs atime keeps its nanoseconds' || fail "attrs atime: $(TZ=UTC stat -c '%x' "$mnt/attrs")"
TZ=UTC stat -c '%y' "$mnt/attrs" | grep -qF '2027-01-15 08:00:00.987654321 +0000' && ok 'attrs mtime keeps its nanoseconds' || fail "attrs mtime: $(TZ=UTC stat -c '%y' "$mnt/attrs")"
[ "$(cat "$mnt/attrs")" = 'metadata oracle' ] && ok 'attrs contents unchanged' || fail 'attrs contents changed'
[ "$(getfattr --only-values -n user.dj "$mnt/protected")" = changed ] && ok 'user.dj replaced' || fail 'user.dj not replaced'
[ "$(getfattr -e hex -n user.com.apple.test "$mnt/protected" | grep -o '0x[0-9a-f]*')" = 0x000102ff ] && ok 'user.com.apple.test holds 00 01 02 ff' || fail 'user.com.apple.test wrong'
getfattr -n user.gone "$mnt/protected" >/dev/null 2>&1 && fail 'user.gone was not removed' || ok 'user.gone removed'
getfattr -n user.com.apple.system.Security "$mnt/protected" >/dev/null 2>&1 && fail 'the refused macOS ACL was stored' || ok 'the refused macOS ACL was not stored'
getfacl -c -n "$mnt/protected" | grep -qx 'user:1002:r--' && ok 'the ACL Linux set on protected is kept' || fail 'protected lost its ACL'
umount "$mnt"
if dmesg | grep -qi recovery; then fail 'the kernel recovered the log'; else ok 'the kernel mounted it with no recovery'; fi
if dmesg | grep -iE 'xfs.*(corrupt|error|shut ?down)'; then fail 'the kernel complained about the volume'; else ok 'the kernel read it all without a complaint'; fi

[ "$fails" -eq 0 ] || { echo "xfs-mutations-linux: $fails check(s) failed"; exit 1; }
echo 'xfs-mutations-linux: all checks passed'
