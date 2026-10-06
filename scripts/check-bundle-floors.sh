#!/usr/bin/env bash
#
# check-bundle-floors.sh — refuse a committed bundle lockfile that resolves
# am-fs-core, or an image-container crate, below the minimum this project has
# actually verified.
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
# floor." FLOORS below holds that floor per crate, bumped by hand when a fix
# in the crate is judged to matter to this project -- the same way
# SIBLING_PINS.txt is bumped by hand for go-networkfs. It is not a general
# "warn about anything behind latest" check; that is a different, harder
# problem (a floor that always trails whatever crates.io just published is
# not a policy anyone would follow), and it is not this script's job to
# invent one -- see the note on agent-skills#34 in the issue this closes.
#
# Usage:  scripts/check-bundle-floors.sh
#         scripts/check-bundle-floors.sh --self-test
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

# Bumped by hand, one line per crate: the crate, its floor, and why.
#
# am-fs-core 0.2.10 is the release fixing the silent-wrong-bytes GPT slice
# defect from diskjockey#90 (am-fs-core CHANGELOG 0.2.5) plus three further
# correctness fixes (0.2.8, 0.2.9, and the pre-0.2.10 Unreleased
# oversize-slice fix) that shipped between the version these bundles had
# been stuck on and this one.
#
# THE IMAGE CRATES (#277). Every bundle links all four, and the EXT4 and
# NTFS extensions open .qcow2/.vhd/.vhdx/.vmdk images through them. They sat
# one and two breaking releases behind with nothing to notice, which is the
# shape #90 was, so they have floors too:
#   am-img-vmdk 0.4.0  concurrent writes lost data while reporting success; a
#                      zeroed grain read as the descriptor; the grain-table
#                      cache was keyed by slot, not table.
#   am-img-vhdx 0.4.0  a log format it could not parse was replayed, and an
#                      unknown Required region was not refused.
#   am-img-qcow2 0.5.0 allocating a cluster wrote past the device's end
#                      instead of asking it for room.
#   am-img-vhd 0.4.0   create_fixed's size agrees with its CHS geometry. No
#                      read-path fix; the floor is what the bundles moved to.
# THE CRATES WERE RENAMED on 2026-10-06 (docs/constellation/naming-discussion.md):
# each am-* crate above is published as rust-* now, at the next minor version,
# and the first rust-* release of each carries every fix named here. So the
# floors below are those first releases, under the new names.
FLOORS=(
    "rust-fs-core 0.3.0"
    "rust-img-qcow2 0.6.0"
    "rust-img-vhd 0.6.0"
    "rust-img-vhdx 0.6.0"
    "rust-img-vmdk 0.5.0"
)

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

# Every version resolved for crate $2 in one Cargo.lock, one per line.
# Empty if the package is not present at all -- a bundle that stopped
# depending on it entirely is not this script's problem to diagnose further,
# and a non-empty-required check downstream will refuse to treat that as a pass.
#
# ALL OF THEM, NOT THE FIRST (#129). This printed the first match and
# exited, so a second `[[package]]` block -- one crate on 0.2, another on
# 0.3 -- was never compared or reported. A lockfile holds one block per
# resolved version, and two resolutions link two copies of the core's Rust
# runtime into one staticlib: the duplicate `_rust_eh_personality` this
# per-bundle layout exists to prevent.
locked_versions() {
    local lockfile="$1" crate="$2"
    awk -v want="name = \"$crate\"" '
        /^\[\[package\]\]/ { hit = 0 }
        $0 == want { hit = 1; next }
        hit && /^version = / { v = $0; gsub(/^version = "|"$/, "", v); print v; hit = 0 }
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
    for floor in "${FLOORS[@]}"; do
        crate="${floor% *}"
        minimum="${floor#* }"
        versions=$(locked_versions "$lockfile" "$crate")
        if [ -z "$versions" ]; then
            echo "[deps] $name: $crate not found in Cargo.lock -- cannot verify the pin" >&2
            fail=1
            continue
        fi
        # ONE RESOLUTION PER BUNDLE, checked before the floor: two that both
        # clear it are still two copies in one staticlib -- two Rust runtimes
        # for the core, and every #[no_mangle] export twice for an image crate.
        # Looping the floor check over each would pass exactly the lockfile
        # this refuses.
        if [ "$(printf '%s\n' "$versions" | wc -l | tr -d ' ')" -gt 1 ]; then
            echo "[deps] $name: Cargo.lock resolves $crate more than once: $(printf '%s\n' "$versions" | tr '\n' ' ')" >&2
            echo "       One per bundle. Align the sibling crates' $crate requirements, then cargo update -p $crate." >&2
            fail=1
            continue
        fi
        v="$versions"
        if ! version_ge "$v" "$minimum"; then
            echo "[deps] $name: $crate $v is below the required floor $minimum" >&2
            echo "       Fix: raise $crate in $bundle/Cargo.toml, (cd $bundle && cargo update -p $crate) && git add $lockfile" >&2
            fail=1
        fi
    done
done

# Non-emptiness first. A glob that matched nothing would report success
# having checked zero bundles -- an empty result read as a clean bill of
# health is the same shape of mistake this issue itself is about.
if [ "$found_any" -eq 0 ]; then
    echo "[deps] no rust-bundles/dj-*-bundle directories found -- nothing was checked" >&2
    exit 1
fi

if [ "$fail" -eq 0 ]; then
    echo "all bundle lockfiles pin each crate once, at or above its floor: ${FLOORS[*]}"
fi
exit "$fail"
