#!/usr/bin/env bash
#
# check-chore-pin.sh — the chore this repository installs is named once
# (diskjockey#79).
#
# Two numbers describe chore here and they mean different things:
#
#   SIBLING_PINS.txt  `chore X.Y.Z`         the release this repository's
#                                           workflows install, exactly
#   chores.yml        `chore_min_version`   the oldest chore that can read
#                                           this repository's chores.yml
#
# They drift in two ways, and both were a version named in two places that
# disagree — the class of defect am-fs-core's pin (#90) cost four CI rounds on:
#
#   - a workflow that installs chore by a literal version, or from a tap with
#     no version at all, so the pin says something no install honours;
#   - a floor raised past the pin, so CI installs a chore this repository has
#     declared too old to read its own contract.
#
# This checks the files; it needs no network and no chore. The root is derived
# from this script's own path, so the test can run it against a scratch tree.
#
#   bash scripts/check-chore-pin.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bad=0
say() { printf 'check-chore-pin: %s\n' "$1" >&2; bad=$((bad + 1)); }

semver='^[0-9]+\.[0-9]+\.[0-9]+$'

pins="$(awk '$1=="chore"{print $2}' "$ROOT/SIBLING_PINS.txt" 2>/dev/null)"
count="$(printf '%s' "$pins" | grep -c . || true)"
pin="$pins"
if [ "$count" != 1 ]; then
    say "SIBLING_PINS.txt must name chore exactly once, found $count"
    pin=""
elif ! printf '%s' "$pin" | grep -qE "$semver"; then
    say "SIBLING_PINS.txt pins chore '$pin', which is not a release version X.Y.Z"
    pin=""
fi

floor="$(sed -n 's/^chore_min_version:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "$ROOT/chores.yml" 2>/dev/null)"
if ! printf '%s' "$floor" | grep -qE "$semver"; then
    say "chores.yml declares no chore_min_version X.Y.Z (found '$floor')"
    floor=""
fi

# version_lt A B: true when A sorts strictly below B, numerically per field.
version_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
        exit 1
    }'
}
if [ -n "$pin" ] && [ -n "$floor" ] && version_lt "$pin" "$floor"; then
    say "SIBLING_PINS.txt installs chore $pin, below chores.yml's chore_min_version $floor"
fi

# Every workflow that installs chore takes the version from the pin.
installs=0
for wf in "$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml; do
    [ -f "$wf" ] || continue
    name="${wf#"$ROOT"/}"
    if grep -qE 'brew[[:space:]]+install[^#]*chore' "$wf"; then
        say "$name installs chore from a tap, whose version SIBLING_PINS.txt does not decide"
    fi
    if grep -qE 'cargo[[:space:]]+install[^#]*chore' "$wf"; then
        say "$name builds chore with cargo install, whose version SIBLING_PINS.txt does not decide"
    fi
    grep -q 'antimatter-studios/chore/releases/download' "$wf" || continue
    installs=$((installs + 1))
    if grep -qE 'chore/releases/download/v?[0-9]|chore-[0-9]+\.[0-9]' "$wf"; then
        say "$name downloads chore by a literal version instead of the SIBLING_PINS.txt pin"
    fi
    if ! grep -qF "awk '\$1==\"chore\"{print \$2}' SIBLING_PINS.txt" "$wf"; then
        say "$name downloads chore without reading its version from SIBLING_PINS.txt"
    fi
done
if [ "$installs" = 0 ]; then
    say "no workflow downloads a chore release, so the pin in SIBLING_PINS.txt is honoured by nothing"
fi

if [ "$bad" -gt 0 ]; then
    exit 1
fi
echo "check-chore-pin: chore $pin, installed from SIBLING_PINS.txt by $installs workflow(s), at or above the floor $floor"
