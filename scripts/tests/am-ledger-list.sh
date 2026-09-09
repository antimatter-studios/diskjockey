#!/usr/bin/env bash
#
# am-ledger-list.sh — `list` filters a COLUMN, or says it is not.
#
# `am-ledger list <filter>` was an unanchored `grep -E` over the whole
# row with `tr ' ' '|'` turning every extra word into an alternation, so
# a filter that looked like it named a column named nothing of the kind.
# `am-ledger list pr` returned 90 rows, 2 of them at stage `pr`; the
# other 88 matched `ci_profile`, `fingerprint`, `prefix`,
# `github-protect-main`. A pipeline decision was taken on that listing
# and later retracted.
#
# WHAT MAKES IT DIFFERENT FROM THE USUAL EMPTY-RESULT DEFECT: the result
# was not empty. An empty result invites suspicion; a screenful of
# plausible rows reads as a successful query, and the standing rule
# about asserting non-emptiness cannot fire on it.
#
# The ledger here is a fixture under AM_LEDGER_DIR, so nothing touches
# the live one.
#
#   bash scripts/tests/am-ledger-list.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LEDGER_BIN="$REPO/scripts/am-ledger"
fails=0

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
export AM_LEDGER_DIR="$sandbox"

# Six rows chosen so every historical false match is present:
#   - a title containing "pr" while the row is NOT at stage pr
#   - a repo name that is a prefix of another repo name
#   - a repo name containing a regex metacharacter
#   - one row genuinely at stage pr
row() { printf '%s\t%s\t%s\t%s\t-\t-\t2026-09-09T00:00:00Z\t%s\n' "$1" "$2" "$3" "$4" "$5"; }
{
    row rust-fs-core   115 accepted fix   "the staticlib task does not fingerprint tests/"
    row rust-fs-core-x 200 fixing   fix-2 "a prefix collision, deliberately"
    row rust-img-qcow2  68 fixing   fix-2 "tests/ci_profile.rs leaves the guard green"
    row rust-fs-xfs    138 pr       fix   "vm-slot.sh carries the generation race"
    row rust-fs-ntfs   254 testing  '-'   "a fingerprint that cannot fail"
    row 'rust.fs.dots'  1  accepted '-'   "a name whose dots are regex metacharacters"
    # THE PAIR IS THE POINT. `rust.fs.dots` matches itself as a regex
    # too, so a row that only a regex would confuse it with is what
    # makes "compares literally" an assertion rather than a wish.
    row 'rustXfsYdots'  2  accepted '-'   "the row a regex would confuse with the dotted one"
} > "$sandbox/issues.tsv"
TOTAL=7

# `list` prints its count on stderr, so stdout is the rows and stderr is
# the commentary. They are captured separately on purpose: a test that
# merged them would be asserting against its own diagnostics.
run() {
    OUT="$("$LEDGER_BIN" list "$@" 2>"$sandbox/err")"
    RC=$?
    ERR="$(cat "$sandbox/err")"
    if [ -z "$OUT" ]; then ROWS=0; else ROWS=$(printf '%s\n' "$OUT" | wc -l | tr -d ' '); fi
}

check_eq() {
    local got="$1" want="$2" what="$3"
    if [ "$got" = "$want" ]; then
        printf 'ok    %s\n' "$what"
    else
        printf 'FAIL  %s: got %s, expected %s\n' "$what" "$got" "$want"
        fails=$((fails + 1))
    fi
}

check_contains() {
    local hay="$1" needle="$2" what="$3"
    case "$hay" in
        *"$needle"*) printf 'ok    %s\n' "$what" ;;
        *) printf 'FAIL  %s: %q does not contain %q\n' "$what" "$hay" "$needle"
           fails=$((fails + 1)) ;;
    esac
}

# --- the defect ------------------------------------------------------

# THE FILED CASE. Under the old reader this returned every row whose
# text contained "pr" ANYWHERE. In this fixture that is five of six:
# `fingerprint` twice, `prefix`, `ci_profile`, and the one row actually
# at stage `pr`. Four of the five have nothing to do with the stage.
run --stage pr
check_eq "$RC" 0 "--stage pr succeeds"
check_eq "$ROWS" 1 "--stage pr returns the one row at stage pr"
check_eq "$(printf '%s' "$OUT" | cut -f1)" rust-fs-xfs "and it is the right one"

# The control on that control: the substrings really are there, so the
# 1 above is a filter working rather than a fixture with nothing in it.
run -- pr
check_eq "$RC" 0 "free text still greps the whole row"
check_eq "$ROWS" 5 "and 'pr' as free text matches five rows, one of them at stage pr"

# --- the column filters are literal and ANDed ------------------------

run --repo rust-fs-core
check_eq "$ROWS" 1 "--repo matches the whole column, not a prefix of another repo"
check_eq "$(printf '%s' "$OUT" | cut -f2)" 115 "and it is rust-fs-core's row, not rust-fs-core-x's"

run --repo rust.fs.dots
check_eq "$ROWS" 1 "--repo compares literally, so dots are dots"
check_eq "$(printf '%s' "$OUT" | cut -f1)" 'rust.fs.dots' \
    "and it is the dotted row, not the one a regex would also have matched"

run --owner fix
check_eq "$ROWS" 2 "--owner matches the owner column"

run --owner fix --stage accepted
check_eq "$ROWS" 1 "two column filters are ANDed, not ORed"
check_eq "$(printf '%s' "$OUT" | cut -f1)" rust-fs-core "and the AND selects the right row"

run --repo rust-fs-xfs --stage accepted
check_eq "$RC" 1 "an AND that selects nothing fails rather than exiting 0"
check_eq "$ROWS" 0 "and prints no rows"
check_contains "$ERR" "matched 0 of $TOTAL rows" "and says how many it matched"

# --- the count is on stderr, on every call ---------------------------

run
check_eq "$ROWS" "$TOTAL" "no filter prints every row"
check_contains "$ERR" "matched $TOTAL of $TOTAL rows" \
    "the count is printed even when nothing was filtered"

run --stage pr
check_contains "$ERR" "matched 1 of $TOTAL rows" "and on a successful filter too"

# THE COUNT LINE MUST NOT LOOK LIKE A ROW. Callers pipe this into
# `awk -F'\t'`, and some of them merge stderr into stdout. A line with
# no tab is invisible to a column filter; a line with tabs would be a
# seventh row.
case "$ERR" in
    *"$(printf '\t')"*) printf 'FAIL  the count line carries a tab and would read as a row\n'
                        fails=$((fails + 1)) ;;
    *) printf 'ok    the count line carries no tab, so it cannot be read as a row\n' ;;
esac

# --- the collision that produced the retracted report ----------------

run pr
check_eq "$RC" 2 "a bare filter that is exactly a stage name is refused"
check_eq "$ROWS" 0 "and prints no rows at all"
check_contains "$ERR" "Did you mean" "and suggests the flag"
check_contains "$ERR" "--stage pr" "naming the stage the caller typed"

# Every stage name, not just the one that bit. `fixing`, `testing` and
# `merged` all appear inside ordinary titles too.
for s in pending accepted rejected fixing testing pr merged failed blocked; do
    run "$s"
    if [ "$RC" != 2 ]; then
        printf 'FAIL  the bare stage name %s is refused: rc=%s\n' "$s" "$RC"
        fails=$((fails + 1))
    fi
done
printf 'ok    every one of the nine stage names is refused as a bare filter\n'

# THE ESCAPE HATCH WORKS, or the refusal is a wall rather than a
# signpost. `-- pr` is how a caller greps for the text.
run -- pr
check_eq "$RC" 0 "-- pr greps for the text instead of refusing"
check_eq "$ROWS" 5 "and finds every row containing it"

# A word that merely CONTAINS a stage name is not a stage name.
run vm-slot
check_eq "$RC" 0 "free text that is not a stage name is not refused"
check_eq "$ROWS" 1 "and still greps"

# --- a stage that is not a stage -------------------------------------

run --stage p
check_eq "$RC" 2 "--stage p is refused rather than matching nothing"
check_contains "$ERR" "is not a stage" "and says why"

run --stage=
check_eq "$RC" 2 "--stage= with no value is refused rather than read as no filter"

run --stage
check_eq "$RC" 2 "--stage with nothing after it is refused"

run --nonsense
check_eq "$RC" 2 "an unknown option is refused rather than grepped for"

# --- free text is unchanged ------------------------------------------

# SEVERAL WORDS ARE STILL AN OR. This is the historical behaviour and
# `list <repo> <num>` depends on it; it is documented rather than
# changed, and pinning it here is what stops a later reader "tidying"
# it into an AND and breaking those callers silently.
run -- rust-fs-core 138
check_eq "$ROWS" 3 "free text ORs its words, as it always has"

if [ "$fails" -eq 0 ]; then
    echo "am-ledger-list: all checks passed"
else
    echo "am-ledger-list: $fails check(s) failed" >&2
fi
exit $(( fails > 0 ))
