#!/usr/bin/env bash
#
# bcachefs-fixtures.sh — refresh the bcachefs images DiskJockeyBCACHEFSCoreTests
# reads, from the images the REFERENCE bcachefs tools made in rust-fs-bcachefs's
# CI.
#
# WHERE THE IMAGES COME FROM. rust-fs-bcachefs's `fixtures` CI job builds every
# fixture inside its harness VM with the reference tools (the reference
# formatter, its FUSE mount and the reference kernel module), records what they
# report beside each image, and uploads the lot as the run's `fixtures`
# artifact. This repository has no VM tooling of its own and runs nothing
# Linux-side for the tests, so it takes a few of those images as they are:
#
#   kernel.img          written and read back by the reference kernel module:
#                       directories, files from empty to 3 MiB, hard links,
#                       symlinks, compressed and checksummed files, subvolumes;
#                       kernel.json is that mount's own listing (path, type,
#                       mode, inode, link count, size, SHA-256, target), and
#                       kernel.dirents.txt the reference lister's dirents.
#   xattr-lengths.img   extended attributes set through the reference mount;
#                       .xattrs.txt and .dirents.txt are the reference lister's.
#   base.img            the write study's base: a directory holding one file,
#                       cleanly unmounted, which the write tests change;
#                       base.super.txt is the reference printer's superblock.
#
# The images are committed gzip'd (sparse 64 MiB images compress to their
# contents), with PROVENANCE.txt naming the run, its commit and the reference
# tools' version. A test that cannot find one fails, naming this script.
#
# Usage: scripts/bcachefs-fixtures.sh [RUN_ID]
#   RUN_ID  a rust-fs-bcachefs CI run whose `fixtures` artifact is still kept
#           (default: the newest successful run on main). Needs `gh`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/DiskJockeyBCACHEFSCoreTests/Fixtures"
REPO=antimatter-studios/rust-fs-bcachefs

run="${1:-}"
if [ -z "$run" ]; then
    run="$(gh run list -R "$REPO" --workflow ci.yml --branch main --status success \
        --limit 1 --json databaseId --jq '.[0].databaseId')"
fi
[ -n "$run" ] || { echo "bcachefs-fixtures: no successful rust-fs-bcachefs CI run found" >&2; exit 1; }
sha="$(gh run view "$run" -R "$REPO" --json headSha --jq .headSha)"

work="$(mktemp -d "${TMPDIR:-/tmp}/bcachefs-fixtures.XXXXXX")"
trap 'rm -rf "$work"' EXIT
gh run download "$run" -R "$REPO" -n fixtures -D "$work"
tar -xzf "$work/fixtures.tar.gz" -C "$work"
src="$work/fixtures"
[ -d "$src" ] || { echo "bcachefs-fixtures: run $run's artifact holds no fixtures/ directory" >&2; exit 1; }

mkdir -p "$OUT"
gzip -9 -n -c "$src/kernel.img" >"$OUT/kernel.img.gz"
cp "$src/kernel.json" "$src/kernel.dirents.txt" "$OUT/"
gzip -9 -n -c "$src/write-study/xattr-lengths.img" >"$OUT/xattr-lengths.img.gz"
cp "$src/write-study/xattr-lengths.xattrs.txt" "$src/write-study/xattr-lengths.dirents.txt" "$OUT/"
gzip -9 -n -c "$src/write-study/base.img" >"$OUT/base.img.gz"
cp "$src/write-study/base.super.txt" "$OUT/"

{
    echo "Made by the reference bcachefs tools in rust-fs-bcachefs's CI, fixtures job."
    echo "run:       https://github.com/$REPO/actions/runs/$run"
    echo "commit:    $sha"
    ref="$(tr -d '[:space:]' <"$src/reference-version.txt" 2>/dev/null || true)"
    [ -n "$ref" ] || ref="metadata version $(sed -n 's/^Version: *//p' "$src/default.super.txt" | head -n 1)"
    echo "reference: $ref"
    echo "files:"
    (cd "$OUT" && shasum -a 256 kernel.img.gz kernel.json kernel.dirents.txt \
        xattr-lengths.img.gz xattr-lengths.xattrs.txt xattr-lengths.dirents.txt \
        base.img.gz base.super.txt \
        | sed 's/^/  /')
} >"$OUT/PROVENANCE.txt"
echo "bcachefs-fixtures: $OUT refreshed from run $run ($sha)"
