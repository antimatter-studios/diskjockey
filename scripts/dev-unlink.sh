#!/usr/bin/env bash
#
# dev-unlink.sh — turn OFF local-dev mode for a driver bundle, restoring it to
# the crates.io-clean state used for distribution builds.
#
# Removes the `[patch.crates-io]` block that dev-link.sh appended to the
# bundle's Cargo.toml and regenerates its Cargo.lock from crates.io.
#
# Usage: scripts/dev-unlink.sh <ext4|ntfs|erofs|squashfs> [--quiet]
# See also: scripts/dev-link.sh, and the "Local co-development" memory.
set -euo pipefail

fs="${1:-}"
quiet=0; [ "${2:-}" = "--quiet" ] && quiet=1
case "$fs" in
    ext4|ntfs|erofs|squashfs) ;;
    *) echo "usage: $0 <ext4|ntfs|erofs|squashfs> [--quiet]" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="$root/rust-bundles/dj-${fs}-bundle"
toml="$bundle/Cargo.toml"
[ -f "$toml" ] || { echo "no bundle Cargo.toml at $toml" >&2; exit 1; }

if grep -q '^# >>> dev-link' "$toml"; then
    # Delete from the start marker to the end marker (inclusive).
    sed -i '' '/^# >>> dev-link/,/^# <<< dev-link/d' "$toml"
    # Trim any trailing blank lines left behind.
    perl -0pi -e 's/\n+\z/\n/' "$toml"
    # Restore a crates.io-resolved lockfile (drop the patched one).
    ( cd "$bundle" && rm -f Cargo.lock && cargo generate-lockfile >/dev/null 2>&1 ) || true
    [ "$quiet" = 1 ] || echo "dev-unlink: dj-${fs}-bundle restored to crates.io (distribution-clean)."
else
    [ "$quiet" = 1 ] || echo "dj-${fs}-bundle is already crates.io-clean (no dev-link patch)."
fi
