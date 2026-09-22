#!/usr/bin/env bash
#
# check-bundle-core-pin.sh (test) — one am-fs-core per bundle (diskjockey#129).
#
# `locked_version` printed the FIRST am-fs-core version in a Cargo.lock and
# exited, so a second resolution was never compared and never reported. Two
# resolutions link two copies of the core's Rust runtime into one staticlib
# (the duplicate `_rust_eh_personality` the per-bundle layout exists to
# avoid), so the plurality itself is the failure -- two cores that both
# clear the floor are still refused.
#
# The script derives its root from its own path, so it is copied into a
# scratch tree with fixture lockfiles. Each run copies the current script.
#
#   bash scripts/tests/check-bundle-core-pin.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

pkg() { printf '[[package]]\nname = "%s"\nversion = "%s"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\n\n' "$1" "$2"; }
# lock <case> <core versions...>: a one-bundle tree whose lockfile resolves them.
lock() {
    local c="$1"; shift
    local d="$sandbox/$c"
    mkdir -p "$d/scripts" "$d/rust-bundles/dj-test-bundle"
    cp "$REPO/scripts/check-bundle-core-pin.sh" "$d/scripts/"
    {
        printf 'version = 3\n\n'
        pkg am-fs-btrfs 0.6.2
        local v; for v in "$@"; do pkg am-fs-core "$v"; done
        pkg libc 0.2.150
    } > "$d/rust-bundles/dj-test-bundle/Cargo.lock"
    OUT="$(bash "$d/scripts/check-bundle-core-pin.sh" 2>&1)"; RC=$?
}
floor=$(grep -oE '^MINIMUM_AM_FS_CORE="[0-9.]+"' "$REPO/scripts/check-bundle-core-pin.sh" | cut -d'"' -f2)

echo "check-bundle-core-pin: one core, at or above the floor ($floor)"

lock single-ok "$floor"
[ "$RC" = 0 ] && ok "one core at the floor passes" || fail "one core at the floor was refused (rc=$RC): $OUT"

lock single-low 0.2.2
[ "$RC" != 0 ] && ok "control: one core below the floor is refused" || fail "control: one core below the floor passed"

lock two-low-second "$floor" 0.2.2
[ "$RC" != 0 ] && ok "a second, older core after a conforming one is refused" \
    || fail "a second core (0.2.2) after a conforming one passed unexamined"

lock two-conforming "$floor" 9.0.0
if [ "$RC" != 0 ]; then ok "two cores that both clear the floor are still refused"
else fail "two conforming cores passed: two Rust runtimes in one staticlib"; fi
case "$OUT" in
    *"$floor"*"9.0.0"*|*"9.0.0"*"$floor"*) ok "the refusal names both versions" ;;
    *) fail "the refusal does not name both versions: $OUT" ;;
esac

bash "$REPO/scripts/check-bundle-core-pin.sh" --self-test >/dev/null 2>&1 \
    && ok "--self-test still passes" || fail "--self-test fails"

echo
if [ "$fails" = 0 ]; then
    echo "check-bundle-core-pin: all checks passed"
else
    echo "check-bundle-core-pin: $fails check(s) failed" >&2
fi
exit "$fails"
