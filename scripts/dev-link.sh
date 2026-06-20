#!/usr/bin/env bash
#
# dev-link.sh — put a driver bundle into LOCAL-DEV mode so you can hack on a
# vendored crate's source and test it in the app WITHOUT publishing a new
# crates.io version each time.
#
# Distribution builds resolve every driver from crates.io (the published,
# proven versions). For local co-development that round-trip is too slow, so
# this appends a `[patch.crates-io]` block to the bundle's Cargo.toml that
# redirects the driver — and the shared `am-fs-core` — to the local vendor/
# submodules. Edit the submodule source, rebuild, see the change immediately.
#
# IMPORTANT: a dev-linked bundle is NOT distribution-clean. Do not commit it.
# Run scripts/dev-unlink.sh <fs> (or `make dev-unlink FS=<fs>`) to restore.
#
# Usage:
#   scripts/dev-link.sh <ext4|ntfs|erofs|squashfs> [extra-crate ...]
#     extra-crate: also redirect another crate to its local submodule, e.g.
#                  `am-img-qcow2` to co-develop the qcow2 reader. (See the
#                  ntfs caveat in the memory: ntfs + a local img reader can
#                  reintroduce a core-path split.)
set -euo pipefail

fs="${1:-}"
case "$fs" in
    ext4|ntfs|erofs|squashfs) ;;
    *) echo "usage: $0 <ext4|ntfs|erofs|squashfs> [extra-crate ...]" >&2; exit 2 ;;
esac
shift

root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="$root/rust-bundles/dj-${fs}-bundle"
toml="$bundle/Cargo.toml"
[ -f "$toml" ] || { echo "no bundle Cargo.toml at $toml" >&2; exit 1; }

# The shared am-fs-core must resolve to the SAME path the driver uses, or
# cargo sees two sources and refuses. ntfs vendors its own rust-fs-core
# (nested); ext4/erofs/squashfs use the shared parent copy.
if [ "$fs" = "ntfs" ]; then
    core_path="../../vendor/rust-fs-ntfs/vendor/rust-fs-core"
else
    core_path="../../vendor/rust-fs-core"
fi

# crate -> submodule dir name
crate_to_dir() {
    case "$1" in
        am-img-*)  echo "rust-img-${1#am-img-}" ;;
        am-fs-*)   echo "rust-fs-${1#am-fs-}" ;;
        am-partitions) echo "rust-partitions" ;;
        *) echo "" ;;
    esac
}

# Idempotent: clear any existing dev-link block first.
"$root/scripts/dev-unlink.sh" "$fs" --quiet

{
    echo ""
    echo "# >>> dev-link: LOCAL DEV — DO NOT COMMIT. Restore: make dev-unlink FS=${fs}"
    echo "[patch.crates-io]"
    echo "am-fs-${fs} = { path = \"../../vendor/rust-fs-${fs}\" }"
    echo "am-fs-core = { path = \"${core_path}\" }"
    for extra in "$@"; do
        dir="$(crate_to_dir "$extra")"
        [ -n "$dir" ] || { echo "skip unknown extra crate '$extra'" >&2; continue; }
        echo "${extra} = { path = \"../../vendor/${dir}\" }"
    done
    echo "# <<< dev-link"
} >> "$toml"

echo "dev-link: dj-${fs}-bundle now resolves the driver + am-fs-core${*:+ + $*} from local vendor/ submodules."
echo "  edit the submodule source, then rebuild the bundle/app to test."
echo "  restore distribution-clean state with:  make dev-unlink FS=${fs}"
if ( cd "$bundle" && cargo build --release --target aarch64-apple-darwin >/dev/null 2>&1 ); then
    echo "  verified: bundle builds with the local override."
else
    echo "  WARNING: bundle build failed with the override — check the [patch] paths / versions." >&2
fi
