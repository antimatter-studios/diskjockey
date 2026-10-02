#!/usr/bin/env bash
#
# am-family-scripts.sh — the constellation audit passes a project that runs
# the family scripts from rust-fs-core, and refuses each way one can still
# carry its own: a committed copy, a bootstrap that drifted from core's, a
# workflow or chores.yml calling a local copy, and a project it could not read.
#
# Fixture trees stand in for GitHub (AM_FAMILY_FIXTURE), built under this
# repository's tmp/ -- not the OS temporary directory -- and removed on exit.
#
#   bash scripts/tests/am-family-scripts.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$REPO/scripts/am-family-scripts"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

mkdir -p "$REPO/tmp"
SANDBOX="$(mktemp -d "$REPO/tmp/am-family-scripts.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM

BOOT='#!/usr/bin/env bash
# the one bootstrap
exec bash "$CORE/scripts/$1.sh"'

core() {
    local d="$SANDBOX/fx/rust-fs-core"
    mkdir -p "$d/scripts" "$d/.github/workflows"
    printf '%s\n' "$BOOT" > "$d/scripts/core.sh"
    for s in output-budget test-floor semver-check family-check; do echo "# $s" > "$d/scripts/$s.sh"; done
    printf 'jobs:\n  t:\n    steps:\n      - run: bash scripts/core.sh test-floor debug 330\n' \
        > "$d/.github/workflows/ci.yml"
}

# good NAME -- a project that does everything right.
good() {
    local d="$SANDBOX/fx/$1"
    mkdir -p "$d/scripts" "$d/.github/workflows"
    printf '%s\n' "$BOOT" > "$d/scripts/core.sh"
    echo "#!/usr/bin/env bash" > "$d/scripts/tier.sh"
    printf "tasks:\n  t:\n    cmds:\n      - 'bash scripts/core.sh test-floor debug 10'\n" > "$d/chores.yml"
    printf '      # the floor was once scripts/test-floor.sh\n      - run: bash scripts/core.sh semver-check\n' \
        > "$d/.github/workflows/ci.yml"
}

run() { OUT="$(AM_FAMILY_FIXTURE="$SANDBOX/fx" bash "$TOOL" "$@" 2>&1)"; RC=$?; }

# --- 1. a clean constellation passes, and a comment is not a call ----------
rm -rf "$SANDBOX/fx"; core; good rust-a; good rust-b
run
[ "$RC" -eq 0 ] && [[ "$OUT" == *"PASS   rust-a"* ]] && [[ "$OUT" == *"3 of 3 projects"* ]] \
    && ok "a constellation with no copies passes, comments naming a script included" \
    || fail "a clean constellation was refused (rc=$RC):"$'\n'"$OUT"

# --- 2. each kind of copy is refused, by project and by reason -------------
rm -rf "$SANDBOX/fx"; core; good rust-a; good rust-copy
echo '# mine' > "$SANDBOX/fx/rust-copy/scripts/test-floor.sh"
run
[ "$RC" -eq 1 ] && [[ "$OUT" == *"FAIL   rust-copy"* ]] && [[ "$OUT" == *"carries a copy: scripts/test-floor.sh"* ]] \
    && [[ "$OUT" == *"PASS   rust-a"* ]] \
    && ok "a committed copy fails that project and no other" \
    || fail "a committed copy was not refused (rc=$RC):"$'\n'"$OUT"

rm -rf "$SANDBOX/fx"; core; good rust-drift
echo '# tweak' >> "$SANDBOX/fx/rust-drift/scripts/core.sh"
run
[ "$RC" -eq 1 ] && [[ "$OUT" == *"scripts/core.sh differs from rust-fs-core's"* ]] \
    && ok "a bootstrap that drifted from core's is refused" \
    || fail "a drifted bootstrap passed (rc=$RC):"$'\n'"$OUT"

rm -rf "$SANDBOX/fx"; core; good rust-none
rm "$SANDBOX/fx/rust-none/scripts/core.sh"
run
[ "$RC" -eq 1 ] && [[ "$OUT" == *"no scripts/core.sh"* ]] \
    && ok "a project with no bootstrap is refused" \
    || fail "a project with no bootstrap passed (rc=$RC):"$'\n'"$OUT"

rm -rf "$SANDBOX/fx"; core; good rust-calls
printf "tasks:\n  t:\n    cmds:\n      - 'scripts/test-floor.sh unit 420'\n" > "$SANDBOX/fx/rust-calls/chores.yml"
run
[ "$RC" -eq 1 ] && [[ "$OUT" == *"chores.yml runs a local copy"* ]] \
    && ok "a chores.yml calling a local copy is refused" \
    || fail "a call to a local copy passed (rc=$RC):"$'\n'"$OUT"

# --- 3. a project that cannot be read is not a pass ------------------------
rm -rf "$SANDBOX/fx"; core; good rust-a
run rust-a rust-missing
[ "$RC" -eq 4 ] && [[ "$OUT" == *"UNREAD rust-missing"* ]] \
    && ok "an unreadable project exits 4 rather than counting as a pass" \
    || fail "an unreadable project was not reported (rc=$RC):"$'\n'"$OUT"

echo
if [ "$fails" -eq 0 ]; then
    echo 'am-family-scripts: all checks passed'
else
    echo "am-family-scripts: $fails check(s) failed" >&2
fi
exit "$((fails > 0))"
