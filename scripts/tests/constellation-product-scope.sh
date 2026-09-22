#!/usr/bin/env bash
# The product pipeline covers DiskJockey and its fifteen modules, and nothing
# from the separate pipeline-infrastructure scope.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

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
antimatter-studios/diskjockey
antimatter-studios/rust-blk-probe
antimatter-studios/rust-fs-btrfs
antimatter-studios/rust-fs-core
antimatter-studios/rust-fs-erofs
antimatter-studios/rust-fs-squashfs
antimatter-studios/rust-fs-xfs
antimatter-studios/rust-img-qcow2
antimatter-studios/rust-img-vhd
antimatter-studios/rust-img-vhdx
antimatter-studios/rust-img-vmdk
antimatter-studios/rust-lzo1x
antimatter-studios/rust-partitions
christhomas/go-networkfs
christhomas/rust-fs-ext4
christhomas/rust-fs-ntfs
EOF
sort -u "$AM_SCOPE_CALLS" > "$actual"

if ! diff -u "$expected" "$actual"; then
    echo "FAIL  overview did not fetch the exact 16-repository product scope" >&2
    exit 1
fi

calls="$(wc -l < "$AM_SCOPE_CALLS" | tr -d ' ')"
unique="$(wc -l < "$actual" | tr -d ' ')"
if [ "$calls" != 16 ] || [ "$unique" != 16 ]; then
    echo "FAIL  expected 16 unique fetches, got $calls calls / $unique unique" >&2
    exit 1
fi

case "$output" in
    *"no open issues in any of the 16 projects"*) ;;
    *) printf 'FAIL  completion output does not state the 16-project scope:\n%s\n' "$output" >&2; exit 1 ;;
esac

echo "constellation-product-scope: all checks passed"
