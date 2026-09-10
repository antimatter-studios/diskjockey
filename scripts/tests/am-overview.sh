#!/usr/bin/env bash
#
# am-overview.sh — the overview table refuses rather than under-reports.
#
# Three of these checks pin defects that were live while the tool was
# being written, and each of them produced a PLAUSIBLE TABLE rather than
# an error:
#
#   - an unlabelled issue shifted every later field left, because TAB is
#     IFS whitespace and `read` collapses a run of them, so titles
#     appeared in the labels column and the title column was empty;
#   - a second copy of the project list can drift from am-ledger's, which
#     is diskjockey#128 in another file;
#   - a timestamp parsed with `date -j -f` and no -u is read as local
#     time, which is diskjockey#132.
#
# Nothing here touches the network: AM_OVERVIEW_FETCH replaces the gh
# call and AM_OVERVIEW_LEDGER_BIN points at a fixture list.
#
#   bash scripts/tests/am-overview.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$REPO/scripts/am-overview"
fails=0
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

check() { # check <what> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "ok — $1"
    else
        echo "FAIL — $1: expected [$2] got [$3]" >&2
        fails=$((fails + 1))
    fi
}
contains() { # contains <what> <needle> <haystack>
    case "$3" in
        *"$2"*) echo "ok — $1" ;;
        *) echo "FAIL — $1: [$2] not in output" >&2; fails=$((fails + 1)) ;;
    esac
}

# A ledger fixture whose list is, by construction, the one the tool carries:
# generated from the tool itself, so "they agree" is not asserted by hand.
mk_ledger() { # mk_ledger <path> [omit-name] [extra-entry]
    local out="$1" omit="${2:-}" extra="${3:-}"
    { echo 'DEFAULT_REPOS=('
      sed -n '/^PROJECTS=(/,/^)/p' "$BIN" | sed -n 's/^[[:space:]]*"\(.*\)".*/    "\1"/p' \
        | { [ -n "$omit" ] && grep -v "\"$omit:" || cat; }
      [ -n "$extra" ] && echo "    \"$extra\""
      echo ')'
    } > "$out"
}

# A fetch stub. Each line of $sandbox/<slug-with-slashes-as-dashes>.rows is
# emitted verbatim; a file named .fail makes the fetch exit non-zero.
cat > "$sandbox/fetch" <<'STUB'
#!/usr/bin/env bash
slug="$1"
key="$(printf '%s' "$slug" | tr '/' '-')"
[ -f "$AM_OVERVIEW_FIXTURES/$key.fail" ] && exit 1
[ -f "$AM_OVERVIEW_FIXTURES/$key.rows" ] && cat "$AM_OVERVIEW_FIXTURES/$key.rows"
exit 0
STUB
chmod +x "$sandbox/fetch"
export AM_OVERVIEW_FETCH="$sandbox/fetch"
export AM_OVERVIEW_FIXTURES="$sandbox"

row() { printf '%s\x1f%s\x1f%s\x1f%s\n' "$1" "$2" "$3" "$4"; }
now_minus() { # seconds -> ISO-8601 Z
    if date -u -r 0 +%s >/dev/null 2>&1; then
        date -u -r "$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ
    else
        date -u -d "@$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ
    fi
}

# ---------------------------------------------------------------- 1. agrees
mk_ledger "$sandbox/ledger-ok"
export AM_OVERVIEW_LEDGER_BIN="$sandbox/ledger-ok"
row 12 "$(now_minus 3600)" - "one hour old"       > "$sandbox/antimatter-studios-agent-skills.rows"
row 13 "$(now_minus 432000)" bug "five days old" >> "$sandbox/antimatter-studios-agent-skills.rows"
out="$("$BIN" --project agent-skills 2>&1)"; rc=$?
check "a matching list runs" 0 "$rc"
contains "the count is the row count" "agent-skills            2" "$out"

# ------------------------------------------------- 2. an hour is not a day
# The whole point of parsing the timestamp as UTC: with `date -j -f` and no
# -u this reads as local time, and an hour-old issue in CEST comes out at
# -1 or 0 depending on sign. diskjockey#132 is the same defect in am-ledger.
contains "an hour old is 0d" "   0d" "$out"
contains "five days old is 5d" "   5d" "$out"

# --------------------------------- 2b. and the offset is what makes it visible
# THE INTEGER DAY IS WHY THE CHECK ABOVE CANNOT SEE THE DEFECT. Dropping -u
# shifts every age by the operator's UTC offset, and a two-hour shift does not
# move a 1-hour-old or a 5-day-old issue across a day boundary — measured: the
# no-utc arm passed all of the checks above. So this one sits 1 hour BELOW a
# boundary, with TZ pinned to a positive-offset zone: correct is 4d, and a
# local-time parse reports 5d. Under TZ=UTC there is no difference at all,
# which is exactly why diskjockey#132 was invisible in CI.
row 14 "$(now_minus $(( 5 * 86400 - 3600 )))" - "just under five days" > "$sandbox/antimatter-studios-agent-skills.rows"
out2="$(TZ=Europe/Berlin "$BIN" --project agent-skills --tsv)"
check "an age just under a boundary stays below it" "4d" "$(printf '%s\n' "$out2" | awk -F'\t' '$2==14 {print $3}')"
row 12 "$(now_minus 3600)" - "one hour old"       > "$sandbox/antimatter-studios-agent-skills.rows"
row 13 "$(now_minus 432000)" bug "five days old" >> "$sandbox/antimatter-studios-agent-skills.rows"

# ------------------------------------------ 3. an empty field shifts nothing
contains "the title is in the title column" "one hour old" "$out"
tsv="$("$BIN" --project agent-skills --tsv)"
check "the labels column holds the label" "bug" "$(printf '%s\n' "$tsv" | awk -F'\t' '$2==13 {print $4}')"
check "the title column holds the title" "five days old" "$(printf '%s\n' "$tsv" | awk -F'\t' '$2==13 {print $5}')"

# ------------------------------------------------------------ 4. drift, ours
mk_ledger "$sandbox/ledger-missing" agent-skills
AM_OVERVIEW_LEDGER_BIN="$sandbox/ledger-missing" out="$("$BIN" --summary 2>&1)"; rc=$?
check "a list the ledger lacks refuses" 3 "$rc"
contains "and names the direction" "only in am-overview" "$out"
contains "and names the project" "agent-skills" "$out"

# ---------------------------------------------------------- 5. drift, theirs
mk_ledger "$sandbox/ledger-extra" "" "rust-fs-zfs:antimatter-studios/rust-fs-zfs"
AM_OVERVIEW_LEDGER_BIN="$sandbox/ledger-extra" out="$("$BIN" --summary 2>&1)"; rc=$?
check "a project only the ledger has refuses" 3 "$rc"
contains "and names that direction too" "only in am-ledger" "$out"

# -------------------------------------------------- 6. unreadable is not ok
: > "$sandbox/ledger-empty"
AM_OVERVIEW_LEDGER_BIN="$sandbox/ledger-empty" out="$("$BIN" --summary 2>&1)"; rc=$?
check "an unparseable ledger refuses" 3 "$rc"
contains "rather than assuming agreement" "refusing to run" "$out"

# ------------------------------------------------------- 7. a failed fetch
export AM_OVERVIEW_LEDGER_BIN="$sandbox/ledger-ok"
: > "$sandbox/antimatter-studios-rust-partitions.fail"
out="$("$BIN" --project agent-skills --project rust-partitions 2>&1)"; rc=$?
check "a failed fetch exits 4" 4 "$rc"
contains "the row says so" "FETCH FAILED" "$out"
contains "and the shortfall is stated" "incomplete BY THAT MUCH" "$out"
contains "while the readable project still counts" "agent-skills            2" "$out"
rm -f "$sandbox/antimatter-studios-rust-partitions.fail"

# --------------------------------------------------------- 8. nothing found
rm -f "$sandbox/antimatter-studios-agent-skills.rows"
out="$("$BIN" --project agent-skills 2>&1)"; rc=$?
check "no issues exits 0" 0 "$rc"
contains "and says so in words" "no open issues" "$out"
case "$out" in
    *PROJECT*) echo "FAIL — an empty result printed a table header" >&2; fails=$((fails + 1)) ;;
    *) echo "ok — an empty result is not an empty table" ;;
esac

# ------------------------------------------------- 9. the filter drops PRs
# The endpoint returns pull requests as issues; without the filter every
# count is wrong in the direction that looks busy.
if command -v jq >/dev/null 2>&1; then
    cat > "$sandbox/two.json" <<'JSON'
[{"number":1,"created_at":"2026-09-01T00:00:00Z","labels":[],"title":"an issue"},
 {"number":2,"created_at":"2026-09-01T00:00:00Z","labels":[],"title":"a pull request",
  "pull_request":{"url":"https://example.invalid/pr/2"}}]
JSON
    got="$(jq -r "$("$BIN" --print-jq)" < "$sandbox/two.json" | wc -l | tr -d ' ')"
    check "a pull request is not an issue" 1 "$got"
    got="$(jq -r "$("$BIN" --print-jq)" < "$sandbox/two.json" | cut -d$'\x1f' -f4)"
    check "and the issue is the one kept" "an issue" "$got"
else
    echo "ok — jq absent, filter check skipped (stated, not silent)"
fi

if [ "$fails" -eq 0 ]; then
    echo "am-overview: all checks passed"
else
    echo "am-overview: $fails check(s) failed" >&2
fi
exit $(( fails > 0 ))
