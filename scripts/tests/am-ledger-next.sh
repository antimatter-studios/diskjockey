#!/usr/bin/env bash
#
# am-ledger-next.sh — which rows `next` can see (diskjockey#157).
#
# `do_next` marks a repository busy for checkout-touching stages when any
# row in it is claimed by someone else. A claimed PENDING row is triage
# holding an issue: it edits no file and holds no worktree, so it cannot
# collide with a fixer. Counting it as busy hid every fixing/testing/pr
# row in that repository from everyone but the triager, which returned
# an empty `next` indistinguishable from a drained queue.
#
# Only `next fixing|testing|pr` reach the exclusion (`case "$want"`), so
# that is what these checks drive. A `next accepted` fixture would pass
# before and after the fix and witness nothing.
#
# The ledger is a fixture under AM_LEDGER_DIR; nothing touches the live one.
#
#   bash scripts/tests/am-ledger-next.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LEDGER_BIN="$REPO/scripts/am-ledger"
fails=0

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
export AM_LEDGER_DIR="$sandbox"
unset AM_LEDGER_PROJECT

row() { printf '%s\t%s\t%s\t%s\t-\t-\t2026-09-16T00:00:00Z\t%s\n' "$1" "$2" "$3" "$4" "$5"; }

check_eq() {
    local got="$1" want="$2" what="$3"
    if [ "$got" = "$want" ]; then
        printf 'ok    %s\n' "$what"
    else
        printf 'FAIL  %s: got [%s], expected [%s]\n' "$what" "$got" "$want"
        fails=$((fails + 1))
    fi
}

# The repo and issue number `next` claimed, or empty.
claim() {
    AM_LEDGER_OWNER="$1" "$LEDGER_BIN" next "$2" 2>/dev/null | cut -f1,2 | tr '\t' '#'
}

echo "am-ledger-next: a claimed pending row"

# 1. THE DEFECT. Repository a's only free fixing row sits beside a pending
#    row that triage has claimed. The fixer must still get it.
{
    row repo-a 1 fixing  '-'    "free work"
    row repo-a 2 pending triage "being read, not edited"
} > "$sandbox/issues.tsv"
check_eq "$(claim fixer fixing)" "repo-a#1" \
    "a pending row claimed by triage does not hide a repository's fixing rows"

# 2. THE CONTROL that makes an empty answer mean something: the same
#    fixture with the claim at a stage that DOES hold a checkout must
#    still exclude the repository. Without it, a fix that deleted the
#    whole exclusion would pass check 1.
{
    row repo-a 1 fixing  '-'   "free work"
    row repo-a 2 fixing  other "someone else's checkout"
} > "$sandbox/issues.tsv"
check_eq "$(claim fixer fixing)" "" \
    "a fixing row claimed by someone else still excludes its repository"

# 3. AND THE SAME FOR THE OTHER TWO STAGES THAT REACH THE EXCLUSION.
for stage in testing pr; do
    {
        row repo-a 1 "$stage" '-'    "free work"
        row repo-a 2 pending  triage "being read"
    } > "$sandbox/issues.tsv"
    check_eq "$(claim worker "$stage")" "repo-a#1" \
        "next $stage is not hidden by a claimed pending row"
done

# 4. PREFERENCE STILL WORKS: with a genuinely busy repository listed first,
#    the free one is chosen.
{
    row repo-a 1 fixing '-'   "free but busy repo"
    row repo-a 2 pr     other "held"
    row repo-b 3 fixing '-'   "free repo"
} > "$sandbox/issues.tsv"
check_eq "$(claim fixer fixing)" "repo-b#3" \
    "a repository held at pr by someone else is skipped for a free one"

echo
if [ "$fails" = 0 ]; then
    echo "am-ledger-next: all checks passed"
else
    echo "am-ledger-next: $fails check(s) failed" >&2
fi
exit "$fails"
