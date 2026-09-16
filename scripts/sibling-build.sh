#!/bin/sh
#
# sibling-build.sh — build a sibling project at its pinned tag, in a
# throwaway worktree, and hand back where the outputs landed.
#
# WHY A WORKTREE RATHER THAN THE CHECKOUT ITSELF
#
# The sibling projects are no longer vendored submodules, so nothing pins
# what is on disk. A developer's checkout is on whatever branch they were
# last working on, possibly dirty, possibly mid-merge — that last one is not
# hypothetical, it happened during the change that introduced this script and
# the build failed with `malformed module path "<<<<<<<"`.
#
# Building from a worktree of a pinned tag means the artifact that goes into
# the app is the same one on every machine, no matter what state the
# developer left their checkout in. The checkout supplies git objects; it
# never supplies the source that gets compiled.
#
# WHAT IT COSTS, MEASURED
#
#   reuse the checkout (chore fingerprint hit)   0.01s
#   fresh worktree, shared build cache           8.7s
#   fresh worktree, cold build cache             20.6s
#
# The cost is real and it is the point: `.chore/` lives inside the worktree,
# so a throwaway tree cannot reuse the previous run's fingerprints and every
# build is a full one. Language-level caches that live outside the tree
# (GOCACHE, CARGO_HOME) still apply, which is why the middle number is not
# the last one.
#
# SUBMODULES ARE THE AWKWARD CASE
#
# `git worktree remove` REFUSES outright on a worktree containing submodules:
#
#   fatal: working trees containing submodules cannot be moved or removed
#
# rust-fs-ntfs has two. So removal escalates — plain remove, then --force,
# then an explicit delete — and the result is VERIFIED rather than assumed,
# because a half-removed worktree leaves a registration that breaks the next
# build with a confusing "already exists".
#
# WHEN THE CHECKOUT IS ON main, IT IS USED DIRECTLY — IF IT IS CLEAN
#
# A worktree exists to escape whatever branch someone is working on. If they
# are on main with nothing modified, there is nothing to escape: the checkout
# already IS the reference state, and using it reuses the chore fingerprint
# cache, which is the difference between 0.01s and 8.7s.
#
# On main and NOT clean, the build STOPS. It does not fall back to a worktree
# and it does not carry on: a dirty or half-merged main is a machine in a
# state its owner did not intend, and no build system can work out what they
# meant. Guessing here would either compile something nobody asked for or
# silently ignore work in progress. The programmer is told what is wrong and
# left to decide — that is the whole of the policy.
#
# USAGE
#   sibling-build.sh <name> <src> <tag> <build-task> <artifact-task> <out>
set -e

NAME="$1"; SRC="$2"; TAG="$3"; BUILD_TASK="$4"; ARTIFACT_TASK="$5"; OUT="$6"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
die() { printf "%b%s%b\n" "$RED" "$1" "$NC" >&2; exit 1; }

[ -n "$NAME" ] && [ -n "$SRC" ] && [ -n "$TAG" ] && [ -n "$OUT" ] \
    || die "usage: sibling-build.sh <name> <src> <tag> <build-task> <artifact-task> <out>"
[ -d "$SRC/.git" ] || [ -f "$SRC/.git" ] || die "no git repository at $SRC"
command -v chore >/dev/null 2>&1 || die "chore is not installed, and it owns the sibling builds"

SRC="$(cd "$SRC" && pwd)"

BRANCH="$( cd "$SRC" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "" )"
# THE STATUS IS READ, NOT ASSUMED (#145). This was
# `git status --porcelain 2>/dev/null | head -20`, so a status git could not
# produce -- a corrupt index, a permissions problem -- left DIRTY empty, and
# an empty DIRTY both skips the dirty-main refusal below and enters "on main,
# clean". Capture the output and the exit status, refuse on failure, and
# truncate for display separately. Not `set -o pipefail`: this is /bin/sh,
# and `| head -20` would make a very dirty tree exit 141.
if STATUS="$( cd "$SRC" && git status --porcelain 2>&1 )"; then
    DIRTY="$( printf '%s\n' "$STATUS" | sed -n '1,20p' )"
    [ -n "$STATUS" ] || DIRTY=""
else
    die "$NAME: could not read git status in $SRC, so whether it is clean is unknown: $STATUS"
fi
MERGING=""
if [ -f "$SRC/.git/MERGE_HEAD" ] || [ -d "$SRC/.git/rebase-merge" ] || [ -d "$SRC/.git/rebase-apply" ]; then
    MERGING="yes"
fi

if [ "$BRANCH" = "main" ] && { [ -n "$DIRTY" ] || [ -n "$MERGING" ]; }; then
    printf "\n%bERROR: %s is on main, but main is not clean.%b\n" "$RED" "$NAME" "$NC" >&2
    echo "" >&2
    echo "  $SRC" >&2
    [ -n "$MERGING" ] && echo "  A merge or rebase is in progress." >&2
    if [ -n "$DIRTY" ]; then
        echo "" >&2
        echo "$DIRTY" | sed 's/^/    /' >&2
        n="$( printf '%s\n' "$STATUS" | wc -l | tr -d " " )"
        [ "$n" -gt 20 ] && echo "    ... and $(( n - 20 )) more" >&2
    fi
    echo "" >&2
    echo "  main must be clean to continue." >&2
    echo "" >&2
    echo "  This is not something the build can decide for you. A dirty main is" >&2
    echo "  a machine left in a state you did not intend, and guessing would" >&2
    echo "  either compile something you did not ask for or quietly discard" >&2
    echo "  work you meant to keep. Commit it, stash it, or finish the merge." >&2
    exit 1
fi

# On main and clean: the checkout already is the reference state, so use it
# and keep the fingerprint cache. Nothing to escape.
if [ "$BRANCH" = "main" ] && [ -z "$DIRTY" ]; then
    [ -f "$SRC/chores.yml" ] || die "$NAME has no chores.yml — it predates the chore migration"
    printf "\n%bBuilding %s from its checkout (on main, clean)%b\n" "$YELLOW" "$NAME" "$NC"
    echo "  source: $SRC"
    ( cd "$SRC" && chore "$BUILD_TASK" ) || die "$NAME: chore $BUILD_TASK failed"
    DIST="$( cd "$SRC" && chore "$ARTIFACT_TASK" )"
    case "$DIST" in /*) ;; *) DIST="$SRC/$DIST" ;; esac
    [ -d "$DIST" ] || die "$NAME: chore $ARTIFACT_TASK named '$DIST', which is not a directory"
    mkdir -p "$OUT"
    cp -R "$DIST"/. "$OUT/"
    {
        echo "lib=$NAME"
        echo "source=$( cd "$SRC" && git config --get remote.origin.url 2>/dev/null || echo unknown )"
        echo "ref=main"
        echo "ref_type=branch"
        echo "commit=$( cd "$SRC" && git rev-parse HEAD )"
        echo "short_commit=$( cd "$SRC" && git rev-parse --short HEAD )"
        echo "built_from=checkout"
        echo "dirty=false"
    } > "$OUT/VERSION-$NAME.txt"
    printf "%b%s ready%b\n" "$GREEN" "$NAME" "$NC"
    echo "  Output:   $OUT/"
    echo "  Manifest: $OUT/VERSION-$NAME.txt"
    exit 0
fi

# Not on main: build the pinned ref in a worktree, so the branch someone
# happens to be working on cannot reach the app's binary.
#
# A tag is the intent, but the pin may still name a branch: no tag in the
# family yet contains its crate's chores.yml, which is the build contract, so
# `main` is the stopgap SIBLING_PINS.txt documents. Resolve either, tag first
# so a branch that shares a name with a tag cannot shadow it.
REF=""
for candidate in "refs/tags/$TAG" "refs/remotes/origin/$TAG" "refs/heads/$TAG"; do
    if ( cd "$SRC" && git rev-parse -q --verify "$candidate" >/dev/null ); then
        REF="$candidate"; break
    fi
done

# Not fetched here. Fetching would make the build depend on the network and on
# whatever upstream currently says, which is the opposite of a pin.
if [ -z "$REF" ]; then
    printf "%bERROR: %s has no tag or branch %s%b\n" "$RED" "$NAME" "$TAG" "$NC" >&2
    printf "  fetch it:  git -C %s fetch --all --tags\n" "$SRC" >&2
    printf "  or repin:  edit SIBLING_PINS.txt\n" >&2
    exit 1
fi

WT="$(mktemp -d "${TMPDIR:-/tmp}/dj-${NAME}-XXXXXX")"
# mktemp made the directory; git worktree add wants to create it itself.
rmdir "$WT"

cleanup() {
    status=$?
    if [ -d "$WT" ]; then
        # Escalating, because `git worktree remove` refuses outright on a
        # worktree containing submodules.
        ( cd "$SRC" && git worktree remove "$WT" ) >/dev/null 2>&1 \
            || ( cd "$SRC" && git worktree remove --force "$WT" ) >/dev/null 2>&1 \
            || rm -rf "$WT"
    fi
    # Always prune: a forced or manual removal leaves the registration
    # behind, and the next build then fails with "already exists".
    ( cd "$SRC" && git worktree prune ) >/dev/null 2>&1 || true

    # Verified, not assumed.
    if [ -d "$WT" ]; then
        printf "%bWARNING: worktree not removed: %s%b\n" "$YELLOW" "$WT" "$NC" >&2
        printf "  remove it by hand; the next build will not reuse it.\n" >&2
        [ "$status" -eq 0 ] && status=1
    fi
    # A FAILED LISTING IS NOT AN EMPTY ONE (#145): `2>/dev/null | grep -q`
    # read a listing git could not produce as "no registration survived".
    if listing="$( cd "$SRC" && git worktree list --porcelain 2>&1 )"; then
        if printf '%s\n' "$listing" | grep -qxF "worktree $WT"; then
            printf "%bWARNING: worktree registration survived in %s%b\n" "$YELLOW" "$SRC" "$NC" >&2
            [ "$status" -eq 0 ] && status=1
        fi
    else
        printf "%bWARNING: could not list worktrees in %s, so whether %s is still registered is unknown: %s%b\n" \
            "$YELLOW" "$SRC" "$WT" "$listing" "$NC" >&2
        [ "$status" -eq 0 ] && status=1
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

printf "\n%bBuilding %s at %s%b\n" "$YELLOW" "$NAME" "$TAG" "$NC"
echo "  source:   $SRC"
echo "  worktree: $WT"

# Detached: a worktree that claimed a branch name would collide with the
# developer's own checkout of it.
( cd "$SRC" && git worktree add --detach "$WT" "$REF" ) >/dev/null \
    || die "could not create a worktree of $TAG"

if [ -f "$WT/.gitmodules" ]; then
    echo "  submodules: initialising (removal will need --force later)"
    ( cd "$WT" && git submodule update --init --recursive ) >/dev/null 2>&1 \
        || die "could not initialise $NAME's submodules in the worktree"
fi

[ -f "$WT/chores.yml" ] || die "$NAME at $TAG has no chores.yml — it predates the chore migration"

( cd "$WT" && chore "$BUILD_TASK" ) || die "$NAME: chore $BUILD_TASK failed at $TAG"

DIST="$( cd "$WT" && chore "$ARTIFACT_TASK" )"
case "$DIST" in
    /*) ;;
    *) DIST="$WT/$DIST" ;;
esac
[ -d "$DIST" ] || die "$NAME: chore $ARTIFACT_TASK named '$DIST', which is not a directory"

mkdir -p "$OUT"
# The contents, not the directory: `artifact` prints a directory precisely
# because there is more than one file to take.
cp -R "$DIST"/. "$OUT/"

# The only record of what went in, now that no gitlink pins it.
{
    echo "lib=$NAME"
    echo "source=$( cd "$SRC" && git config --get remote.origin.url 2>/dev/null || echo unknown )"
    echo "ref=$TAG"
    case "$REF" in refs/tags/*) echo "ref_type=tag" ;; *) echo "ref_type=branch" ;; esac
    echo "commit=$( cd "$WT" && git rev-parse HEAD )"
    echo "short_commit=$( cd "$WT" && git rev-parse --short HEAD )"
    echo "built_from=worktree"
    echo "dirty=false"
} > "$OUT/VERSION-$NAME.txt"

printf "%b%s ready at %s%b\n" "$GREEN" "$NAME" "$TAG" "$NC"
echo "  Output:   $OUT/"
echo "  Manifest: $OUT/VERSION-$NAME.txt"
