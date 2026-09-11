#!/usr/bin/env bash
#
# check-bundle-core-pin.sh — refuse a committed bundle lockfile that resolves
# am-fs-core below the minimum this project has actually verified.
#
# WHY THIS EXISTS RATHER THAN RELYING ON the guards' pre-commit rust-deps-pinned.
# That hook's `cargo metadata --locked` check (part 4) asks "is this lockfile
# still valid against these manifests" -- it passes as long as the LOCKED
# am-fs-core version still satisfies whatever the LOCKED am-fs-btrfs (etc.)
# happened to require when IT was published. A bundle can sit on am-fs-core
# 0.2.2 indefinitely and that check stays green, because 0.2.2 was a valid
# resolution the day the lock was written and nothing forces it to move
# forward. Six bundles did exactly that for eight releases, missing a
# silent-wrong-bytes fix in 0.2.5, until Greptile caught it on #77 and it
# still wasn't fixed at review time. See diskjockey#90.
#
# So this asks a different, narrower question: not "is the lock internally
# consistent" but "does it name a version we have actually decided is the
# floor." MINIMUM_AM_FS_CORE below is that floor, bumped by hand when a fix
# in am-fs-core is judged to matter to this project -- the same way
# SIBLING_PINS.txt is bumped by hand for go-networkfs. It is not a general
# "warn about anything behind latest" check; that is a different, harder
# problem (a floor that always trails whatever crates.io just published is
# not a policy anyone would follow), and it is not this script's job to
# invent one -- see the note on agent-skills#34 in the issue this closes.
#
# Usage:  scripts/check-bundle-core-pin.sh
#         scripts/check-bundle-core-pin.sh --self-test
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

# Bumped by hand. 0.2.10 is the release fixing the silent-wrong-bytes GPT
# slice defect from diskjockey#90 (am-fs-core CHANGELOG 0.2.5) plus three
# further correctness fixes (0.2.8, 0.2.9, and the pre-0.2.10 Unreleased
# oversize-slice fix) that shipped between the version these bundles had
# been stuck on and this one.
MINIMUM_AM_FS_CORE="0.2.10"

# Compare two dotted-numeric versions field by field. Returns 0 (true) if
# $1 >= $2.
#
# NOT A STRING COMPARISON. "0.2.9" > "0.2.10" as strings -- the '9' sorts
# after the '1' -- which is exactly backwards, and a version-floor check
# built on `[[ "$v" > "$min" ]]` would pass a genuinely stale 0.2.9 against
# a 0.2.10 floor while looking correct on every version pair someone
# actually tries by hand (single-digit patch numbers). See --self-test.
version_ge() {
    local a="$1" b="$2"
    local -a af bf
    IFS='.' read -r -a af <<<"$a"
    IFS='.' read -r -a bf <<<"$b"
    local i n
    n=${#af[@]}
    [ "${#bf[@]}" -gt "$n" ] && n=${#bf[@]}
    for ((i = 0; i < n; i++)); do
        local av=${af[i]:-0} bv=${bf[i]:-0}
        if ((10#$av > 10#$bv)); then
            return 0
        elif ((10#$av < 10#$bv)); then
            return 1
        fi
    done
    return 0 # equal
}

# Read the version pinned for `am-fs-core` in one Cargo.lock. Empty if the
# package is not present at all -- a bundle that stopped depending on it
# entirely is not this script's problem to diagnose further, and a
# non-empty-required check downstream will refuse to treat that as a pass.
locked_version() {
    local lockfile="$1"
    awk '
        $0 == "name = \"am-fs-core\"" { hit = 1; next }
        hit && /^version = / { gsub(/^version = "|"$/, "", $0); print; exit }
    ' "$lockfile"
}

if [ "${1:-}" = "--self-test" ]; then
    fail=0
    check() {
        local a="$1" b="$2" want="$3" got
        if version_ge "$a" "$b"; then got=true; else got=false; fi
        if [ "$got" != "$want" ]; then
            echo "SELF-TEST FAILED: version_ge($a, $b) = $got, want $want" >&2
            fail=1
        fi
    }
    # THE TRAP ITSELF: single-digit patch below a double-digit one. A
    # string comparison gets every one of these backwards.
    check "0.2.9" "0.2.10" false
    check "0.2.10" "0.2.9" true
    check "0.9.9" "0.10.0" false
    check "1.2.3" "1.2.3" true
    check "1.2.3" "1.2.4" false
    check "1.2.4" "1.2.3" true
    check "2.0.0" "1.99.99" true
    check "0.2.2" "0.2.10" false
    check "0.2.10" "0.2.2" true
    # A missing field defaults to 0, so a bare "1.2" compares as "1.2.0".
    check "1.2" "1.2.0" true
    check "1.2" "1.2.1" false
    if [ "$fail" -eq 0 ]; then
        echo "version_ge behaves correctly on every case, including the string-compare trap"
    fi
    exit "$fail"
fi

fail=0
found_any=0
for bundle in "$root"/rust-bundles/dj-*-bundle; do
    lockfile="$bundle/Cargo.lock"
    [ -f "$lockfile" ] || continue
    found_any=1
    name=$(basename "$bundle")
    v=$(locked_version "$lockfile")
    if [ -z "$v" ]; then
        echo "[deps] $name: am-fs-core not found in Cargo.lock -- cannot verify the pin" >&2
        fail=1
        continue
    fi
    if ! version_ge "$v" "$MINIMUM_AM_FS_CORE"; then
        echo "[deps] $name: am-fs-core $v is below the required floor $MINIMUM_AM_FS_CORE" >&2
        echo "       Fix: (cd $bundle && cargo update -p am-fs-core) && git add $lockfile" >&2
        fail=1
    fi
done

# Non-emptiness first. A glob that matched nothing would report success
# having checked zero bundles -- an empty result read as a clean bill of
# health is the same shape of mistake this issue itself is about.
if [ "$found_any" -eq 0 ]; then
    echo "[deps] no rust-bundles/dj-*-bundle directories found -- nothing was checked" >&2
    exit 1
fi

if [ "$fail" -eq 0 ]; then
    echo "all bundle lockfiles pin am-fs-core >= $MINIMUM_AM_FS_CORE"
fi
exit "$fail"
