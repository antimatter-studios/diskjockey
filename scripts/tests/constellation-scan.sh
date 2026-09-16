#!/usr/bin/env bash
#
# constellation-scan.sh — the evidence scan does not report a scan that did
# not run as a zero (diskjockey#104).
#
# docs/constellation/scan.sh counted with
# `grep ... 2>/dev/null | paste -sd+ - | bc 2>/dev/null` and printed
# `${n:-0}`, so a genuine zero, a sibling that is not checked out, and a
# machine without `bc` all printed the same `0` -- in the script whose job
# is producing evidence.
#
# The scan reads siblings beside the repository, so it is copied into a
# scratch parent directory with fixture siblings.
#
#   bash scripts/tests/constellation-scan.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

SIBLINGS=$(sed -n 's/^REPOS="\(.*\)"$/\1/p' "$REPO/docs/constellation/scan.sh")
[ -n "$SIBLINGS" ] || { echo "FAIL  could not read REPOS from scan.sh"; exit 1; }

tree() { # tree <case> [sibling-to-omit]
    local root="$sandbox/$1" r
    mkdir -p "$root/diskjockey/docs/constellation"
    cp "$REPO/docs/constellation/scan.sh" "$root/diskjockey/docs/constellation/"
    for r in $SIBLINGS; do
        [ "$r" = "${2:-}" ] && continue
        mkdir -p "$root/$r/src"
        echo 'pub fn other() {}' > "$root/$r/src/lib.rs"
    done
    # Two endian helpers in one crate, so the count under test is non-zero.
    [ "rust-fs-ext4" = "${2:-}" ] || printf 'pub fn le_u16() {}\npub fn be_u32() {}\n' > "$root/rust-fs-ext4/src/bytes.rs"
    printf '%s' "$root"
}
scan() { # scan <root> [PATH]
    mkdir -p "$1/job"
    ( cd "$1/diskjockey" && PATH="${2:-$PATH}" CLAUDE_JOB_DIR="$1/job" bash docs/constellation/scan.sh >"$1/stdout" 2>&1 ); RC=$?
    OUT="$(cat "$1/job/tmp/constellation-evidence.txt" 2>/dev/null; cat "$1/stdout")"
}

echo "constellation-scan: a count means a count"

root=$(tree complete); scan "$root"
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -qx 'rust-fs-ext4: 2' && printf '%s\n' "$OUT" | grep -qx 'rust-fs-ntfs: 0'; then
    ok "control: a complete constellation counts 2 and a genuine 0"
else
    fail "control: complete constellation (rc=$RC): $(printf '%s\n' "$OUT" | grep -E '^rust-fs-(ext4|ntfs):' | tr '\n' ' ')"
fi

root=$(tree missing rust-fs-ntfs); scan "$root"
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'rust-fs-ntfs'; then
    ok "a sibling that is not checked out stops the scan and is named"
else
    fail "a missing sibling was reported as data (rc=$RC): $(printf '%s\n' "$OUT" | grep -E '^rust-fs-ntfs:' | tr '\n' ' ')"
fi

root=$(tree nobc); mkdir -p "$root/bin"; printf '#!/bin/sh\necho "bc: not installed" >&2\nexit 127\n' > "$root/bin/bc"; chmod +x "$root/bin/bc"
scan "$root" "$root/bin:$PATH"
if printf '%s\n' "$OUT" | grep -qx 'rust-fs-ext4: 2'; then
    ok "a machine without bc still counts 2, not 0"
else
    fail "without bc the count was: $(printf '%s\n' "$OUT" | grep -E '^rust-fs-ext4:' || echo absent)"
fi

echo
if [ "$fails" = 0 ]; then
    echo "constellation-scan: all checks passed"
else
    echo "constellation-scan: $fails check(s) failed" >&2
fi
exit "$fails"
