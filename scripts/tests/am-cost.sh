#!/usr/bin/env bash
#
# am-cost.sh — a row that is wrong is refused, not recorded (diskjockey#142).
#
# `am-cost add` checked arity and nothing else, and every way of getting a
# row wrong made the recorded cost read LOWER: a non-numeric token count
# counted the run and not the tokens (141027 per run became 70513), a
# swapped <stage> <tokens> invented a stage named 99999, and a newline in
# the note forged a whole third row. All exited 0.
#
# The cost file is a scratch AM_COST_FILE; the real one is never touched.
#
#   bash scripts/tests/am-cost.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COST="$REPO/scripts/am-cost"
fails=0
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
export AM_COST_FILE="$sandbox/cost.tsv"

ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
lines() { [ -f "$AM_COST_FILE" ] && wc -l < "$AM_COST_FILE" | tr -d ' ' || echo 0; }

# refused <what> <args...>: exits non-zero and writes nothing.
refused() {
    local what="$1"; shift
    local before after rc
    before=$(lines); "$COST" add "$@" >/dev/null 2>"$sandbox/err"; rc=$?; after=$(lines)
    if [ "$rc" -ne 0 ] && [ "$before" = "$after" ]; then ok "refused: $what"
    else fail "$what was recorded (rc=$rc, rows $before -> $after)"; fi
}

echo "am-cost: add refuses a wrong row"

# ACCEPTANCE FIRST, so every refusal below is a refusal of the input and
# not of the tool.
"$COST" add rust-fs-xfs 164 audit 141027 47 "the skip pattern row" >/dev/null 2>&1 \
    && [ "$(lines)" = 1 ] && ok "a correct row is recorded" || fail "a correct row was not recorded"
"$COST" add rust-fs-core 126 triage 20000 >/dev/null 2>&1 \
    && [ "$(lines)" = 2 ] && ok "a correct row without tools or note is recorded" || fail "a minimal correct row was not recorded"

refused "a non-numeric token count"                 rust-fs-core 126 audit lots 12 typo
refused "<stage> and <tokens> swapped"              rust-img-vhd 70 99999 audit
refused "a non-numeric issue number"                rust-img-vhd seventy audit 100
refused "a non-numeric tools count"                 rust-img-vhd 70 audit 100 many
refused "a row-state word used as a stage (fixing)" rust-img-vhd 70 fixing 100
refused "a newline in the note"                     repoB 2 audit 100000 10 $'line one\nrepoC\t3\ttriage\t999999\t0\tinjected'
refused "a tab in the note"                         repoB 2 audit 100000 10 $'a\tb'
refused "a tab in the repository"                   $'repo\tB' 2 audit 100000

echo "am-cost: report does not average in what it cannot read"
# A file anything can append to: a hand-written bad row must be counted
# and named, not coerced to zero and averaged in.
printf '2026-09-16T00:00:00Z\trust-fs-core\t126\taudit\tlots\t12\ttypo\n' >> "$AM_COST_FILE"
out=$("$COST" report 2>&1)
if printf '%s\n' "$out" | grep -qE '^  audit +141027 +1 +141027$'; then ok "the audit average is untouched by the unreadable row (141027 per run)"
else fail "the audit line moved: $(printf '%s\n' "$out" | grep audit)"; fi
case "$out" in
    *"1 row unreadable"*) ok "report says how many rows it could not read" ;;
    *) fail "report does not mention the unreadable row: $out" ;;
esac
if printf '%s\n' "$out" | grep -qE '^ +2 distinct issues$'; then ok "the unreadable row adds no issue"
else fail "distinct issue count changed: $(printf '%s\n' "$out" | tail -1)"; fi

echo
if [ "$fails" = 0 ]; then
    echo "am-cost: all checks passed"
else
    echo "am-cost: $fails check(s) failed" >&2
fi
exit "$fails"
