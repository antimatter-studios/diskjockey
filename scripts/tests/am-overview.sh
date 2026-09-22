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
#   - duplicated project lists can drift or share the same omission, so all
#     consumers now source one product manifest (diskjockey#170);
#   - a timestamp parsed with `date -j -f` and no -u is read as local
#     time, which is diskjockey#132.
#
# Nothing here touches the network: AM_OVERVIEW_FETCH replaces the gh
# call.
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

# The same for the --list pull request lookup: <key>.prs rows, <key>.prsfail.
cat > "$sandbox/fetch-prs" <<'STUB'
#!/usr/bin/env bash
key="$(printf '%s' "$1" | tr '/' '-')"
[ -f "$AM_OVERVIEW_FIXTURES/$key.prsfail" ] && exit 1
[ -f "$AM_OVERVIEW_FIXTURES/$key.prs" ] && cat "$AM_OVERVIEW_FIXTURES/$key.prs"
exit 0
STUB
chmod +x "$sandbox/fetch-prs"
export AM_OVERVIEW_FETCH_PRS="$sandbox/fetch-prs"

# And the summary's PR counts: <key>.prcounts holds `<open> <closed>`,
# absent means `0 0`, <key>.prcountsfail fails.
cat > "$sandbox/fetch-pr-counts" <<'STUB'
#!/usr/bin/env bash
key="$(printf '%s' "$1" | tr '/' '-')"
[ -f "$AM_OVERVIEW_FIXTURES/$key.prcountsfail" ] && exit 1
if [ -f "$AM_OVERVIEW_FIXTURES/$key.prcounts" ]; then cat "$AM_OVERVIEW_FIXTURES/$key.prcounts"; else echo "0 0"; fi
STUB
chmod +x "$sandbox/fetch-pr-counts"
export AM_OVERVIEW_FETCH_PR_COUNTS="$sandbox/fetch-pr-counts"
export AM_OVERVIEW_FIXTURES="$sandbox"

row() { printf '%s\x1f%s\x1f%s\x1f%s\n' "$1" "$2" "$3" "$4"; }
now_minus() { # seconds -> ISO-8601 Z
    if date -u -r 0 +%s >/dev/null 2>&1; then
        date -u -r "$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ
    else
        date -u -d "@$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ
    fi
}

# ------------------------------------------------------------------ 1. runs
row 12 "$(now_minus 3600)" - "one hour old"       > "$sandbox/antimatter-studios-diskjockey.rows"
row 13 "$(now_minus 432000)" bug "five days old" >> "$sandbox/antimatter-studios-diskjockey.rows"
out="$("$BIN" --project diskjockey 2>&1)"; rc=$?
check "the canonical product list runs" 0 "$rc"
contains "the count is the row count" "diskjockey              2" "$out"

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
row 14 "$(now_minus $(( 5 * 86400 - 3600 )))" - "just under five days" > "$sandbox/antimatter-studios-diskjockey.rows"
out2="$(TZ=Europe/Berlin "$BIN" --project diskjockey --tsv)"
check "an age just under a boundary stays below it" "4d" "$(printf '%s\n' "$out2" | awk -F'\t' '$2==14 {print $3}')"
row 12 "$(now_minus 3600)" - "one hour old"       > "$sandbox/antimatter-studios-diskjockey.rows"
row 13 "$(now_minus 432000)" bug "five days old" >> "$sandbox/antimatter-studios-diskjockey.rows"

# ------------------------------------------ 3. an empty field shifts nothing
contains "the title is in the title column" "one hour old" "$out"
tsv="$("$BIN" --project diskjockey --tsv)"
check "the labels column holds the label" "bug" "$(printf '%s\n' "$tsv" | awk -F'\t' '$2==13 {print $4}')"
check "the title column holds the title" "five days old" "$(printf '%s\n' "$tsv" | awk -F'\t' '$2==13 {print $5}')"

# ------------------------------------------------------- 4. a failed fetch
: > "$sandbox/antimatter-studios-rust-partitions.fail"
out="$("$BIN" --project diskjockey --project rust-partitions 2>&1)"; rc=$?
check "a failed fetch exits 4" 4 "$rc"
contains "the row says so" "FETCH FAILED" "$out"
contains "and the shortfall is stated" "incomplete BY THAT MUCH" "$out"
contains "while the readable project still counts" "diskjockey              2" "$out"
rm -f "$sandbox/antimatter-studios-rust-partitions.fail"

# ------------------------------------------------ 4b. the list names everyone
# Every project gets a heading, including one with nothing open and one whose
# fetch failed, so the list cannot read as complete when it is not.
: > "$sandbox/antimatter-studios-rust-partitions.fail"
out="$("$BIN" --list --project diskjockey --project rust-partitions --project rust-lzo1x 2>&1)"; rc=$?
check "a failed fetch in the list still exits 4" 4 "$rc"
contains "the list heads each project with its count" "diskjockey — 2 open" "$out"
contains "the list prints issue number and title" "five days old" "$out"
contains "each issue carries its link" "https://github.com/antimatter-studios/diskjockey/issues/13 " "$out"
contains "a failed project is named in the list" "rust-partitions — FETCH FAILED" "$out"
contains "an empty project is named, not skipped" "rust-lzo1x — 0 open" "$out"
rm -f "$sandbox/antimatter-studios-rust-partitions.fail"

# ------------------------------------------- 4c. pull requests in the list
# Two PRs on one issue take two lines, and the title stays on the first.
PR=https://github.com/antimatter-studios/diskjockey/pull
printf '13\x1f%s/20 %s/21\n' "$PR" "$PR" > "$sandbox/antimatter-studios-diskjockey.prs"
out="$("$BIN" --list --project diskjockey 2>&1)"; rc=$?
check "the list with pull requests exits 0" 0 "$rc"
check "the first PR shares the issue's line" 1 "$(printf '%s\n' "$out" | grep -c "issues/13 .*pull/20 .*five days old")"
check "the second PR has a line of its own" 1 "$(printf '%s\n' "$out" | grep -Ec "^ +$PR/21$")"
check "an issue without PRs says so" 1 "$(printf '%s\n' "$out" | grep -Ec "issues/12 +- +one hour old")"
rm -f "$sandbox/antimatter-studios-diskjockey.prs"

# A PR lookup that fails is not "no pull requests".
: > "$sandbox/antimatter-studios-diskjockey.prsfail"
out="$("$BIN" --list --project diskjockey 2>&1)"; rc=$?
check "a failed PR lookup exits 4" 4 "$rc"
contains "the PR column says it failed" "FETCH FAILED" "$out"
contains "and the shortfall names the lookup" "diskjockey (pull requests)" "$out"
rm -f "$sandbox/antimatter-studios-diskjockey.prsfail"

# ------------------------------------------- 4d. pull request counts
echo "3 40" > "$sandbox/antimatter-studios-diskjockey.prcounts"
echo "1 2" > "$sandbox/antimatter-studios-rust-partitions.prcounts"
out="$("$BIN" --summary --project diskjockey --project rust-partitions 2>&1)"; rc=$?
check "the summary with PR counts exits 0" 0 "$rc"
check "the row ends in open and closed PRs" 1 "$(printf '%s\n' "$out" | grep -Ec '^diskjockey +2 .* 3 +40$')"
check "the total sums both PR columns" 1 "$(printf '%s\n' "$out" | grep -Ec '^TOTAL +2 +4 +42$')"

# An unreadable count is `?`, never 0, and the total says it is partial.
: > "$sandbox/antimatter-studios-rust-partitions.prcountsfail"
out="$("$BIN" --summary --project diskjockey --project rust-partitions 2>&1)"; rc=$?
check "a failed PR count exits 4" 4 "$rc"
check "the row shows it as unknown" 1 "$(printf '%s\n' "$out" | grep -Ec '^rust-partitions +0 .* \? +\?$')"
check "and the total is marked partial" 1 "$(printf '%s\n' "$out" | grep -Ec '^TOTAL .* 3\+\? +40\+\?$')"
contains "and the shortfall names the lookup" "rust-partitions (pull request counts)" "$out"
rm -f "$sandbox"/*.prcounts "$sandbox"/*.prcountsfail

# ------------------------------------------------ 4e. a rate limit stops it
# Once GitHub is rate limiting the token, every later request fails the same
# way. Carrying on only spends more of the limit and prints a table of
# FETCH FAILED rows, so the run stops at the first one, says why, and makes
# no further request. The stub logs each fetch it serves.
calls="$sandbox/calls"
cat > "$sandbox/fetch-limited" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$AM_OVERVIEW_CALLS"
key="$(printf '%s' "$1" | tr '/' '-')"
if [ -f "$AM_OVERVIEW_FIXTURES/$key.ratelimit" ]; then
    echo "gh: $(cat "$AM_OVERVIEW_FIXTURES/$key.ratelimit")" >&2
    exit 1
fi
exit 0
STUB
chmod +x "$sandbox/fetch-limited"
for message in "API rate limit exceeded for user ID 1. (HTTP 403)" \
               "You have exceeded a secondary rate limit. (HTTP 403)" \
               "GraphQL: API rate limit already exceeded for user ID 1. (RATE_LIMITED)"; do
    : > "$calls"
    printf '%s' "$message" > "$sandbox/antimatter-studios-rust-partitions.ratelimit"
    out="$(AM_OVERVIEW_CALLS="$calls" AM_OVERVIEW_FETCH="$sandbox/fetch-limited" \
        "$BIN" --summary --project diskjockey --project rust-partitions --project rust-lzo1x 2>&1)"; rc=$?
    check "a rate limit exits 5 [$message]" 5 "$rc"
    contains "and says it was rate limited [$message]" "rate limit" "$out"
    contains "and where it stopped [$message]" "stopped at rust-partitions" "$out"
    check "and makes no request after it [$message]" 2 "$(wc -l < "$calls" | tr -d ' ')"
    case "$out" in
        *PROJECT*) echo "FAIL — a rate-limited run printed a table [$message]" >&2; fails=$((fails + 1)) ;;
        *) echo "ok — a rate-limited run prints no table [$message]" ;;
    esac
done
rm -f "$sandbox/antimatter-studios-rust-partitions.ratelimit"

# The same for the pull request lookups, which run after the issue fetch.
printf 'GraphQL: API rate limit already exceeded (RATE_LIMITED)' > "$sandbox/limited-msg"
cat > "$sandbox/fetch-counts-limited" <<'STUB'
#!/usr/bin/env bash
echo "gh: $(cat "$AM_OVERVIEW_FIXTURES/limited-msg")" >&2
exit 1
STUB
chmod +x "$sandbox/fetch-counts-limited"
out="$(AM_OVERVIEW_FETCH_PR_COUNTS="$sandbox/fetch-counts-limited" \
    "$BIN" --summary --project diskjockey --project rust-partitions 2>&1)"; rc=$?
check "a rate-limited PR count exits 5" 5 "$rc"
contains "and names the lookup" "stopped at diskjockey (pull request counts)" "$out"

# An ordinary failure is still an ordinary failure: exit 4, the run goes on.
: > "$sandbox/antimatter-studios-rust-partitions.fail"
out="$("$BIN" --summary --project rust-partitions --project diskjockey 2>&1)"; rc=$?
check "a failure that is not a rate limit still exits 4" 4 "$rc"
contains "and the next project is still read" "diskjockey              2" "$out"
rm -f "$sandbox/antimatter-studios-rust-partitions.fail"

# --------------------------------------------------------- 5. nothing found
rm -f "$sandbox/antimatter-studios-diskjockey.rows"
out="$("$BIN" --project diskjockey 2>&1)"; rc=$?
check "no issues exits 0" 0 "$rc"
contains "and says so in words" "no open issues" "$out"
case "$out" in
    *PROJECT*) echo "FAIL — an empty result printed a table header" >&2; fails=$((fails + 1)) ;;
    *) echo "ok — an empty result is not an empty table" ;;
esac

# ------------------------------------------------- 6. the filter drops PRs
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

    # Closing references and mentions are merged, deduplicated, and put in
    # PR number order — /pull/100 after /pull/99, not before it as text.
    cat > "$sandbox/prs.json" <<'JSON'
{"data":{"repository":{"issues":{"nodes":[
 {"number":5,
  "closedByPullRequestsReferences":{"nodes":[{"number":100,"url":"u/pull/100"}]},
  "timelineItems":{"nodes":[
    {"source":{"__typename":"PullRequest","number":100,"url":"u/pull/100"}},
    {"source":{"__typename":"Issue"}},
    {"source":{"__typename":"PullRequest","number":99,"url":"u/pull/99"}}]}},
 {"number":6,
  "closedByPullRequestsReferences":{"nodes":[]},
  "timelineItems":{"nodes":[{"source":{"__typename":"Issue"}}]}}]}}}}
JSON
    got="$(jq -r "$("$BIN" --print-pr-jq)" < "$sandbox/prs.json" | tr '\037' '|')"
    check "PRs are merged, deduplicated and ordered; issues without any are omitted" "5|u/pull/99 u/pull/100" "$got"
else
    echo "ok — jq absent, filter check skipped (stated, not silent)"
fi

if [ "$fails" -eq 0 ]; then
    echo "am-overview: all checks passed"
else
    echo "am-overview: $fails check(s) failed" >&2
fi
exit $(( fails > 0 ))
