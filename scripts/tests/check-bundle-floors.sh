#!/usr/bin/env bash
#
# check-bundle-floors.sh (test) — one am-fs-core per bundle (diskjockey#129),
# and every floored crate at or above its floor (#277).
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
# The image crates are floored too (#277), so every fixture lockfile carries
# them at their floors, and a case below proves each is checked.
#
#   bash scripts/tests/check-bundle-floors.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

pkg() { printf '[[package]]\nname = "%s"\nversion = "%s"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\n\n' "$1" "$2"; }
floors="$(sed -n '/^FLOORS=(/,/^)/p' "$REPO/scripts/check-bundle-floors.sh" | grep -oE '"[a-z0-9-]+ [0-9.]+"' | tr -d '"')"
floor_of() { printf '%s\n' "$floors" | awk -v c="$1" '$1 == c { print $2 }'; }
floor="$(floor_of am-fs-core)"
# lock <case> <core versions...>: a one-bundle tree whose lockfile resolves
# them, beside every other floored crate at its floor -- or, for one crate
# named in $OVERRIDE as "crate v1 [v2]", at those versions instead ("DROP"
# leaves it out).
lock() {
    local c="$1"; shift
    local d="$sandbox/$c"
    mkdir -p "$d/scripts" "$d/rust-bundles/dj-test-bundle"
    cp "$REPO/scripts/check-bundle-floors.sh" "$d/scripts/"
    {
        printf 'version = 3\n\n'
        pkg am-fs-btrfs 0.6.2
        local v; for v in "$@"; do pkg am-fs-core "$v"; done
        local crate min
        while read -r crate min; do
            [ "$crate" = am-fs-core ] && continue
            if [ "${OVERRIDE%% *}" = "$crate" ]; then
                for v in ${OVERRIDE#* }; do [ "$v" = DROP ] || pkg "$crate" "$v"; done
            else
                pkg "$crate" "$min"
            fi
        done <<<"$floors"
        pkg libc 0.2.150
    } > "$d/rust-bundles/dj-test-bundle/Cargo.lock"
    OUT="$(bash "$d/scripts/check-bundle-floors.sh" 2>&1)"; RC=$?
}
OVERRIDE=""
[ -n "$floor" ] && [ "$(printf '%s\n' "$floors" | wc -l)" -ge 5 ] \
    && ok "the floors are read from the script: $(printf '%s' "$floors" | tr '\n' ',')" \
    || fail "could not read FLOORS out of scripts/check-bundle-floors.sh: '$floors'"

echo "check-bundle-floors: one of each crate, at or above its floor (core $floor)"

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

vmdk="$(floor_of am-img-vmdk)"
OVERRIDE="am-img-vmdk 0.3.5" lock vmdk-low "$floor"
[ "$RC" != 0 ] && [[ "$OUT" == *"am-img-vmdk 0.3.5 is below the required floor $vmdk"* ]] \
    && ok "an image crate below its floor is refused, by name" \
    || fail "am-img-vmdk 0.3.5 against a floor of $vmdk was not refused by name (rc=$RC): $OUT"
OVERRIDE="am-img-qcow2 $(floor_of am-img-qcow2) 9.0.0" lock qcow2-twice "$floor"
[ "$RC" != 0 ] && [[ "$OUT" == *"resolves am-img-qcow2 more than once"* ]] \
    && ok "an image crate resolved twice is refused: its C exports would link twice" \
    || fail "two am-img-qcow2 resolutions passed (rc=$RC): $OUT"
OVERRIDE="am-img-vhdx DROP"
lock vhdx-missing "$floor"
[ "$RC" != 0 ] && [[ "$OUT" == *"am-img-vhdx not found in Cargo.lock"* ]] \
    && ok "control: a lockfile missing a floored crate is refused, by name" \
    || fail "a lockfile without am-img-vhdx passed"
OVERRIDE=""

bash "$REPO/scripts/check-bundle-floors.sh" --self-test >/dev/null 2>&1 \
    && ok "--self-test still passes" || fail "--self-test fails"

echo
if [ "$fails" = 0 ]; then
    echo "check-bundle-floors: all checks passed"
else
    echo "check-bundle-floors: $fails check(s) failed" >&2
fi
exit "$fails"
