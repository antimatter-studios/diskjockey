#!/usr/bin/env bash
#
# sibling-build.sh — a query that fails is not a clean answer
# (diskjockey#145).
#
# Two checks in scripts/sibling-build.sh read the permissive answer from a
# query that failed. `git status --porcelain 2>/dev/null | head -20` leaves
# DIRTY empty when git cannot read the checkout, and an empty DIRTY both
# SKIPS the dirty-main refusal and ENTERS "on main, clean: build from the
# checkout" -- the guard disarmed and its property asserted in one step. And
# the post-build `git worktree list --porcelain 2>/dev/null | grep -qF` finds
# nothing when the listing fails, so a surviving registration is not
# reported.
#
# `chore` is a stub on PATH that records what it was asked to do; the
# siblings are scratch repositories. Nothing outside the sandbox is touched.
#
#   bash scripts/tests/sibling-build.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB="$REPO/scripts/sibling-build.sh"
fails=0
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
export TMPDIR="$sandbox/tmp"; mkdir -p "$TMPDIR"
export GIT_CONFIG_GLOBAL="$sandbox/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com; git config --global user.name t
git config --global init.defaultBranch main

ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

mkdir -p "$sandbox/bin"
cat > "$sandbox/bin/chore" <<'STUB'
#!/bin/sh
echo "$1" >> "$CHORE_LOG"
case "$1" in
    build) mkdir -p dist && echo lib > dist/lib.a ;;
    artifact) echo dist ;;
esac
STUB
chmod +x "$sandbox/bin/chore"
REAL_GIT="$(command -v git)"
export PATH="$sandbox/bin:$PATH"

sibling() { # a repository on main with chores.yml committed
    local d="$sandbox/$1"; mkdir -p "$d"
    ( cd "$d" && git init -q && echo 'tasks: {}' > chores.yml && git add chores.yml && git commit -qm init )
    printf '%s' "$d"
}
run() { CHORE_LOG="$sandbox/chore-$1.log"; export CHORE_LOG; : > "$CHORE_LOG"; shift
    sh "$SB" "$@" > "$sandbox/out" 2>&1; RC=$?; OUT="$(cat "$sandbox/out")"; }

echo "sibling-build: an unanswered query is not clean"

# CONTROL: a clean checkout on main builds from the checkout.
src=$(sibling clean)
run clean lib "$src" main build artifact "$sandbox/out-clean"
if [ "$RC" = 0 ] && grep -qx build "$sandbox/chore-clean.log"; then ok "control: a clean main checkout builds from the checkout"
else fail "control: a clean main checkout did not build (rc=$RC): $OUT"; fi

# CONTROL: a genuinely dirty main is refused.
src=$(sibling dirty); echo change >> "$src/chores.yml"
run dirty lib "$src" main build artifact "$sandbox/out-dirty"
if [ "$RC" != 0 ] && ! grep -qx build "$sandbox/chore-dirty.log"; then ok "control: a dirty main is refused without building"
else fail "control: a dirty main was not refused (rc=$RC)"; fi

# CONTROL: a VERY dirty main (more than the 20 lines shown) is refused with
# the overflow count. This is the case a `pipefail` remedy would break:
# `| head -20` exits 141 when the producer has more to write.
src=$(sibling verydirty); for i in $(seq 1 25); do echo x > "$src/untracked-$i"; done
run verydirty lib "$src" main build artifact "$sandbox/out-verydirty"
if [ "$RC" != 0 ] && ! grep -qx build "$sandbox/chore-verydirty.log" && printf '%s' "$OUT" | grep -q '\.\.\. and 5 more'; then
    ok "control: a main with 25 changes is refused and reports '... and 5 more'"
else
    fail "control: a very dirty main (rc=$RC): $(printf '%s' "$OUT" | grep -E 'more|ERROR' | head -2 | tr '\n' ' ')"
fi

# 1. THE DEFECT: git cannot read the checkout's status (a corrupt index).
src=$(sibling corrupt); printf 'this is not an index' > "$src/.git/index"
( cd "$src" && "$REAL_GIT" status --porcelain >/dev/null 2>&1 ) && fail "harness: git status unexpectedly succeeds on the corrupt index"
run corrupt lib "$src" main build artifact "$sandbox/out-corrupt"
if [ "$RC" != 0 ] && ! grep -qx build "$sandbox/chore-corrupt.log"; then
    ok "a checkout whose status cannot be read is refused, not built as clean"
else
    fail "a checkout whose status cannot be read was built as clean (rc=$RC, chore ran: $(tr '\n' ' ' < "$sandbox/chore-corrupt.log"))"
fi

# 2. A FAILED WORKTREE LISTING IS NOT "NO REGISTRATION". Build a pinned ref
#    from a checkout that is NOT on main, with `git worktree list` failing.
src=$(sibling listing); ( cd "$src" && git checkout -qb work )
cat > "$sandbox/bin/git" <<STUB
#!/bin/sh
[ "\$1" = worktree ] && [ "\$2" = list ] && { echo "fatal: simulated listing failure" >&2; exit 128; }
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$sandbox/bin/git"
run listing lib "$src" main build artifact "$sandbox/out-listing"
rm -f "$sandbox/bin/git"
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'could not list worktrees'; then
    ok "a worktree listing that fails is reported and fails the build"
else
    fail "a failed worktree listing passed silently (rc=$RC)"
fi

echo
if [ "$fails" = 0 ]; then
    echo "sibling-build: all checks passed"
else
    echo "sibling-build: $fails check(s) failed" >&2
fi
exit "$fails"
