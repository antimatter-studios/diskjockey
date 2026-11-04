#!/usr/bin/env bash
# The product pipeline covers DiskJockey, its modules, the Windows drivers and
# the skeleton they share, and the two test harnesses their oracles run in,
# and nothing from the separate pipeline-infrastructure scope.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# The cache lives in this run's sandbox. am-overview keeps every answer for ten
# minutes, so against the normal cache a second run reads the stub answers of
# the first and fetches too little, and every run leaves synthetic answers
# there for the real command to read (#566).
export XDG_CACHE_HOME="$sandbox/cache"

cat > "$sandbox/fetch" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$AM_SCOPE_CALLS"
exit 0
STUB
chmod +x "$sandbox/fetch"

export AM_OVERVIEW_FETCH="$sandbox/fetch"
cat > "$sandbox/pr-counts" <<'STUB'
#!/usr/bin/env bash
echo "0 0"
STUB
chmod +x "$sandbox/pr-counts"
export AM_OVERVIEW_FETCH_PR_COUNTS="$sandbox/pr-counts"
export AM_SCOPE_CALLS="$sandbox/calls"

output="$($REPO/scripts/am-overview --summary 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    printf 'FAIL  product inventory exited %s:\n%s\n' "$rc" "$output" >&2
    exit 1
fi

expected="$sandbox/expected"
actual="$sandbox/actual"
cat > "$expected" <<'EOF'
antimatter-studios/btrfs-win-driver
antimatter-studios/diskjockey
antimatter-studios/erofs-win-driver
antimatter-studios/ext4-win-driver
antimatter-studios/fs-linux-test-harness
antimatter-studios/fs-windows-test-harness
antimatter-studios/go-networkfs
antimatter-studios/rust-blk-probe
antimatter-studios/rust-disk-partitions
antimatter-studios/rust-fs-bcachefs
antimatter-studios/rust-fs-btrfs
antimatter-studios/rust-fs-core
antimatter-studios/rust-fs-erofs
antimatter-studios/rust-fs-exfat
antimatter-studios/rust-fs-ext4
antimatter-studios/rust-fs-ntfs
antimatter-studios/rust-fs-squashfs
antimatter-studios/rust-fs-xfs
antimatter-studios/rust-img-qcow2
antimatter-studios/rust-img-vhd
antimatter-studios/rust-img-vhdx
antimatter-studios/rust-img-vmdk
antimatter-studios/rust-lzo1x
antimatter-studios/winfsp-fs-skeleton
antimatter-studios/xfs-win-driver
EOF
LC_ALL=C sort -u "$AM_SCOPE_CALLS" > "$actual"

if ! diff -u "$expected" "$actual"; then
    echo "FAIL  overview did not fetch the exact 25-repository product scope" >&2
    exit 1
fi

calls="$(wc -l < "$AM_SCOPE_CALLS" | tr -d ' ')"
unique="$(wc -l < "$actual" | tr -d ' ')"
if [ "$calls" != 25 ] || [ "$unique" != 25 ]; then
    echo "FAIL  expected 25 unique fetches, got $calls calls / $unique unique" >&2
    exit 1
fi

case "$output" in
    *"no open issues in any of the 25 projects"*) ;;
    *) printf 'FAIL  completion output does not state the 25-project scope:\n%s\n' "$output" >&2; exit 1 ;;
esac

# Run again, beside a normal cache that already holds an answer for every
# repository (#566). The guard runs itself once with that cache found through
# HOME and once through XDG_CACHE_HOME: each run must still fetch the whole
# inventory, so it read nothing there, and the cache must come out unchanged.
if [ -z "${AM_SCOPE_NESTED:-}" ]; then
    normal="$sandbox/normal"
    while IFS= read -r slug; do
        mkdir -p "$normal/.cache/am/github/$slug"
        printf '1\0372026-01-01T00:00:00Z\037-\037a kept answer\n' \
            > "$normal/.cache/am/github/$slug/overview-issues"
        printf '9 9\n' > "$normal/.cache/am/github/$slug/overview-pr-counts"
    done < "$expected"

    # Every path with its modification time, and each file's checksum: a new
    # entry, a refreshed one and a temporary file left behind all show here.
    snapshot() (
        cd "$normal" || exit 1
        find . | LC_ALL=C sort | while IFS= read -r path; do
            stat -c '%n %Y' "$path" 2>/dev/null || stat -f '%N %m' "$path"
            [ ! -f "$path" ] || cksum < "$path"
        done
    )
    before="$(snapshot)"

    for found_through in HOME XDG_CACHE_HOME; do
        if [ "$found_through" = HOME ]; then
            nested="$(env -u XDG_CACHE_HOME HOME="$normal" AM_SCOPE_NESTED=1 \
                bash "${BASH_SOURCE[0]}" 2>&1)"
        else
            nested="$(HOME="$normal" XDG_CACHE_HOME="$normal/.cache" AM_SCOPE_NESTED=1 \
                bash "${BASH_SOURCE[0]}" 2>&1)"
        fi
        rc=$?
        if [ "$rc" -ne 0 ] || [ "${nested##*$'\n'}" != "constellation-product-scope: all checks passed" ]; then
            printf 'FAIL  a run beside a kept cache (found through %s) exited %s:\n%s\n' \
                "$found_through" "$rc" "$nested" >&2
            exit 1
        fi
        if [ "$(snapshot)" != "$before" ]; then
            echo "FAIL  a run changed the normal cache (found through $found_through)" >&2
            exit 1
        fi
    done
fi

echo "constellation-product-scope: all checks passed"
