#!/usr/bin/env bash
# bump-toolchain.sh — bump the pinned Rust toolchain across ALL vendor crates
# in lockstep, verify each, and open a PR per repo.
#
# WHY THIS EXISTS
# ---------------
# Every vendor crate pins its rustc via its own `rust-toolchain.toml`, and
# DiskJockey's FSKit extensions statically link several of those crates'
# `.a` files into one binary. Linking staticlibs built by *different* rustc
# versions into a single Mach-O produces a duplicate `_rust_eh_personality`
# symbol at link time. The pins therefore MUST move together — if one repo's
# toml drifts ahead (or behind) the others, the next extension build breaks.
#
# This script makes "bump the toolchain everywhere" a single command instead
# of a hand-edited, easy-to-desync chore across N repos.
#
# WHAT IT DOES (safe phase, the default)
#   For each vendor crate that has a rust-toolchain.toml:
#     1. fetch origin, branch `chore/toolchain-<version>` off the default branch
#     2. rewrite the `channel = "..."` line to <version>
#     3. verify under the new toolchain: cargo fmt --check, clippy -D warnings,
#        and tests (release profile, matching how the .a is built)
#     4. commit, push, and open a PR
#   Crates already pinned at <version> are skipped.
#
# WHAT IT DELIBERATELY DOES NOT DO
#   - It never merges PRs, pushes version tags, or publishes to crates.io.
#     Those are irreversible / need human judgement and stay manual.
#   - After the per-repo PRs are merged, re-point the parent submodules with:
#         scripts/bump-toolchain.sh --repin
#     which advances each submodule to its merged default branch, regenerates
#     VENDOR_PINS.txt (`make pins`), and opens the parent PR. Tagging the
#     crate releases (which triggers crates.io publish) remains a manual step.
#
# USAGE
#   scripts/bump-toolchain.sh <version> [--dry-run] [--no-verify] [--no-pr]
#   scripts/bump-toolchain.sh --repin   [--dry-run]
#
#   <version>     e.g. 1.96.0 — the rustc channel to pin everywhere.
#   --dry-run     print what would change; touch nothing.
#   --no-verify   skip the cargo fmt/clippy/test gate (NOT recommended).
#   --no-pr       commit + push the branch but do not open a PR.
#   --repin       parent-side: bump submodule pointers to merged defaults +
#                 regenerate VENDOR_PINS.txt + open the DiskJockey PR.
#
# REQUIREMENTS: bash, git, gh (authenticated), rustup with the target toolchain
# installable. Run from anywhere inside the repo.

set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'

SRCROOT="$(git rev-parse --show-toplevel)"
cd "$SRCROOT"

# ---- arg parsing -----------------------------------------------------------
VERSION=""
MODE="bump"
DRY_RUN=0
NO_VERIFY=0
NO_PR=0

for arg in "$@"; do
    case "$arg" in
        --dry-run)   DRY_RUN=1 ;;
        --no-verify) NO_VERIFY=1 ;;
        --no-pr)     NO_PR=1 ;;
        --repin)     MODE="repin" ;;
        -h|--help)   sed -n '2,55p' "$0"; exit 0 ;;
        --*)         echo "${RED}unknown flag: $arg${NC}" >&2; exit 2 ;;
        *)           VERSION="$arg" ;;
    esac
done

run() { # echo + execute, unless --dry-run
    if [ "$DRY_RUN" = 1 ]; then echo "  ${YELLOW}[dry-run]${NC} $*"; else "$@"; fi
}

# Default branch of the current repo's origin (e.g. main / master).
# refs/remotes/origin/HEAD is NOT populated in a submodule checkout, so ask
# the host via gh first, then fall back to parsing `git remote show`, then main.
default_branch() {
    gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null \
        || git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' \
        || echo main
}

# ---- crate discovery -------------------------------------------------------
# A vendor crate is bumpable iff it carries its own rust-toolchain.toml.
discover_crates() {
    local d
    for d in "$SRCROOT"/vendor/*/; do
        [ -f "${d}rust-toolchain.toml" ] && basename "$d"
    done
}

current_channel() { # <crate-dir>
    grep -E '^[[:space:]]*channel[[:space:]]*=' "$1/rust-toolchain.toml" \
        | head -1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/'
}

# ===========================================================================
# MODE: repin (parent side, after crate PRs merge)
# ===========================================================================
if [ "$MODE" = "repin" ]; then
    [ -n "$VERSION" ] && echo "${YELLOW}note: --repin ignores the version argument '${VERSION}'.${NC}"
    echo "${BOLD}Re-pinning parent submodules to merged default branches…${NC}"
    changed=0
    while read -r crate; do
        dir="vendor/$crate"
        ( cd "$dir" && git fetch --quiet origin )
        db="$(cd "$dir" && default_branch)"
        old="$(cd "$dir" && git rev-parse --short HEAD)"
        new="$(cd "$dir" && git rev-parse --short "origin/$db")"
        if [ "$old" = "$new" ]; then
            printf "  %-26s %s (unchanged)\n" "$crate" "$old"
            continue
        fi
        printf "  %-26s %s -> %s\n" "$crate" "$old" "$new"
        run bash -c "cd '$dir' && git checkout --quiet 'origin/$db'"
        changed=1
    done < <(discover_crates)

    if [ "$changed" = 0 ]; then
        echo "${GREEN}All submodules already at their merged defaults. Nothing to do.${NC}"
        exit 0
    fi

    # `run` echoes (and skips) in dry-run; only swallow make's output for real.
    if [ "$DRY_RUN" = 1 ]; then echo "  ${YELLOW}[dry-run]${NC} make pins"; else make pins >/dev/null; fi
    branch="chore/bump-vendor-toolchain-pins"
    run git checkout -B "$branch"
    run git add VENDOR_PINS.txt vendor/
    run git commit -m "build: advance vendor submodules to their bumped toolchain builds"
    run git push -u origin "$branch"
    [ "$NO_PR" = 1 ] || run gh pr create --fill --base "$(default_branch)" --head "$branch"
    echo "${GREEN}Parent re-pin prepared. Review the PR, then tag/publish crates as needed.${NC}"
    exit 0
fi

# ===========================================================================
# MODE: bump (per-crate, the default)
# ===========================================================================
if [ -z "$VERSION" ]; then
    echo "${RED}error: no version given.${NC} usage: scripts/bump-toolchain.sh <version> [flags]" >&2
    exit 2
fi
if ! echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "${RED}error: '$VERSION' is not an X.Y.Z rustc version.${NC}" >&2
    exit 2
fi

echo "${BOLD}Bumping vendor crates to Rust ${VERSION}…${NC}"
branch="chore/toolchain-${VERSION}"
summary=""
skipped=""

while read -r crate; do
    dir="$SRCROOT/vendor/$crate"
    cur="$(current_channel "$dir")"
    if [ "$cur" = "$VERSION" ]; then
        skipped+="  ${crate} (already ${VERSION})\n"
        continue
    fi

    echo "${YELLOW}── ${crate}: ${cur} -> ${VERSION} ──${NC}"
    (
        cd "$dir"
        run git fetch --quiet origin
        db="$(default_branch)"
        run git checkout --quiet -B "$branch" "origin/$db"
        # Rewrite ONLY the channel line; leave comments/components intact.
        if [ "$DRY_RUN" = 0 ]; then
            perl -0pi -e "s/(channel\\s*=\\s*\")[^\"]+(\")/\${1}${VERSION}\${2}/" rust-toolchain.toml
        fi

        if [ "$NO_VERIFY" = 0 ]; then
            echo "  verifying under ${VERSION} (fmt / clippy / test)…"
            run rustup toolchain install "$VERSION" --profile minimal --component clippy,rustfmt --no-self-update
            run rustup run "$VERSION" cargo fmt --check
            run rustup run "$VERSION" cargo clippy --all-targets -- -D warnings
            run rustup run "$VERSION" cargo test --release
        fi

        # Stage ONLY the toml — never -a, which would sweep in any other dirty
        # tracked file (leftover artifacts, half-applied patches) silently.
        run git add rust-toolchain.toml
        run git commit -m "chore(toolchain): bump pinned Rust ${cur} -> ${VERSION}"
        run git push -u origin "$branch"
        if [ "$NO_PR" = 0 ]; then
            run gh pr create --base "$db" --head "$branch" \
                --title "chore: bump pinned Rust toolchain to ${VERSION}" \
                --body "Aligns the pinned Rust toolchain to ${VERSION} in rust-toolchain.toml. Verified locally: fmt --check, clippy --all-targets -D warnings, and test --release under ${VERSION}."
        fi
    )
    summary+="  ${GREEN}✓${NC} ${crate}: ${cur} -> ${VERSION}\n"
done < <(discover_crates)

echo
echo "${BOLD}Summary${NC}"
[ -n "$summary" ] && printf "%b" "$summary"
[ -n "$skipped" ] && { echo "Skipped:"; printf "%b" "$skipped"; }
echo
echo "${BOLD}Next steps (manual — irreversible / need review):${NC}"
echo "  1. Review + merge each crate PR once its CI is green."
echo "  2. Tag each released crate (vX.Y.Z) if publishing to crates.io."
echo "  3. Run: scripts/bump-toolchain.sh --repin   (re-points parent submodules)."
