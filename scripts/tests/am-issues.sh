#!/usr/bin/env bash
#
# am-issues.sh — the constellation's open issues, oldest first, as data.
#
# The order is the exact moment each issue was opened, across every project;
# every entry carries what a program needs to act on it; a failed fetch is not
# "no issues"; and each project's answer is cached per repository, so asking
# again within the TTL asks GitHub nothing (#544). Nothing here touches the
# network: AM_ISSUES_FETCH and AM_ISSUES_FETCH_PRS replace the gh calls, and
# the cache lives in this run's sandbox.
#
#   bash scripts/tests/am-issues.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$REPO/scripts/am-issues"
fails=0
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

check() { # check <what> <expected> <actual>
    [ "$2" = "$3" ] && return 0
    echo "FAIL — $1: expected [$2] got [$3]"
    fails=$((fails + 1))
}

finish() {
    if [ "$fails" -eq 0 ]; then
        echo "am-issues: all checks passed"
    else
        echo "am-issues: $fails check(s) failed"
    fi
    exit $(( fails > 0 ))
}

# The output is JSON, so this guard reads it with jq. Without jq it cannot
# check anything, and says so by failing rather than passing unread.
if ! command -v jq >/dev/null 2>&1; then
    check "jq is installed (this guard reads am-issues' JSON with it)" yes no
    finish
fi
if [ ! -x "$BIN" ]; then
    check "scripts/am-issues exists and is executable" yes no
    finish
fi

# <slug-with-dashes>.rows and .prs are printed verbatim; .fail and .prsfail
# fail; .ratelimit fails with its text on stderr. Every call is logged.
cat > "$sandbox/fetch" <<'STUB'
#!/usr/bin/env bash
key="$(printf '%s' "$1" | tr '/' '-')"
printf 'issues %s\n' "$key" >> "$AM_ISSUES_CALLS"
[ ! -f "$AM_ISSUES_FIXTURES/$key.ratelimit" ] || { cat "$AM_ISSUES_FIXTURES/$key.ratelimit" >&2; exit 1; }
[ -f "$AM_ISSUES_FIXTURES/$key.fail" ] && exit 1
[ -f "$AM_ISSUES_FIXTURES/$key.rows" ] && cat "$AM_ISSUES_FIXTURES/$key.rows"
exit 0
STUB
cat > "$sandbox/fetch-prs" <<'STUB'
#!/usr/bin/env bash
key="$(printf '%s' "$1" | tr '/' '-')"
printf 'prs %s\n' "$key" >> "$AM_ISSUES_CALLS"
[ -f "$AM_ISSUES_FIXTURES/$key.prsfail" ] && exit 1
[ -f "$AM_ISSUES_FIXTURES/$key.prs" ] && cat "$AM_ISSUES_FIXTURES/$key.prs"
exit 0
STUB
chmod +x "$sandbox/fetch" "$sandbox/fetch-prs"
export AM_ISSUES_FETCH="$sandbox/fetch" AM_ISSUES_FETCH_PRS="$sandbox/fetch-prs"
export AM_ISSUES_FIXTURES="$sandbox" AM_ISSUES_CALLS="$sandbox/calls"
export XDG_CACHE_HOME="$sandbox/cache"
unset AM_GITHUB_CACHE_TTL
: > "$AM_ISSUES_CALLS"
ncalls() { wc -l < "$AM_ISSUES_CALLS" | tr -d ' '; }
exists() { if [ -e "$1" ]; then echo yes; else echo no; fi; }
cached() { printf '%s/am/github/antimatter-studios/%s/%s' "$XDG_CACHE_HOME" "$1" "$2"; }

GH=https://github.com/antimatter-studios
# A row as --print-jq makes it: created, claimed, number, link, the entry.
row() { # row <repo> <created> <number> <claimed 0|1> <labels JSON> <title JSON>
    local url="$GH/$1/issues/$3"
    printf '%s\t%s\t%s\t%s\t{"created":"%s","labels":%s,"number":%s,"title":%s,"url":"%s"}\n' \
        "$2" "$4" "$3" "$url" "$2" "$5" "$3" "$6" "$url"
}
f="$sandbox/antimatter-studios-diskjockey.rows"
row diskjockey 2026-10-05T12:38:42Z 301 0 '[]' '"one naming scheme"' > "$f"
row diskjockey 2026-09-11T10:12:33Z 165 0 '["bug"]' '"Path \"A\"\tnever launches"' >> "$f"
row diskjockey 2026-10-07T16:38:55Z 325 1 '["claimed","claim/agent-0000-2026-10-07"]' '"a claimed issue"' >> "$f"
f="$sandbox/antimatter-studios-rust-fs-ntfs.rows"
row rust-fs-ntfs 2026-10-14T12:26:14Z 580 0 '[]' '"a second later"' > "$f"
row rust-fs-ntfs 2026-09-06T19:06:44Z 137 0 '["bug"]' '"the oldest"' >> "$f"
row rust-fs-ntfs 2026-10-14T12:26:13Z 579 0 '[]' '"a second earlier"' >> "$f"
P=(--project diskjockey --project rust-fs-ntfs --project rust-lzo1x)

# ------------------------------------------------- 1. the order, the fields
out="$("$BIN" "${P[@]}" 2>"$sandbox/err")"; rc=$?
check "the list exits 0" 0 "$rc"
check "the list is a JSON array" array "$(printf '%s' "$out" | jq -r 'type' 2>&1)"
check "oldest first, by the exact moment, across projects" \
    "rust-fs-ntfs#137 diskjockey#165 diskjockey#301 diskjockey#325 rust-fs-ntfs#579 rust-fs-ntfs#580" \
    "$(printf '%s' "$out" | jq -r '[.[] | "\(.project)#\(.number)"] | join(" ")' 2>&1)"
check "each entry carries its link" "$GH/rust-fs-ntfs/issues/137" "$(printf '%s' "$out" | jq -r '.[0].url')"
check "its exact creation time" 2026-09-06T19:06:44Z "$(printf '%s' "$out" | jq -r '.[0].created')"
check "its labels" bug "$(printf '%s' "$out" | jq -r '.[0].labels | join(",")')"
check "and its title, quotes and tabs intact" $'Path "A"\tnever launches' \
    "$(printf '%s' "$out" | jq -r '.[] | select(.number == 165) | .title')"
check "a project with nothing open adds nothing" 0 \
    "$(printf '%s' "$out" | jq '[.[] | select(.project == "rust-lzo1x")] | length')"
check "and a clean run says nothing on stderr" "" "$(cat "$sandbox/err")"

# ------------------------------------------------------------ 2. the filters
out="$("$BIN" "${P[@]}" --unclaimed)"
check "--unclaimed drops the issues labelled claimed" "137 165 301 579 580" \
    "$(printf '%s' "$out" | jq -r '[.[].number | tostring] | join(" ")')"
out="$("$BIN" "${P[@]}" --urls)"
check "--urls is an array of the links, in the same order" \
    "$GH/rust-fs-ntfs/issues/137 $GH/diskjockey/issues/165 $GH/diskjockey/issues/301 $GH/diskjockey/issues/325 $GH/rust-fs-ntfs/issues/579 $GH/rust-fs-ntfs/issues/580" \
    "$(printf '%s' "$out" | jq -r 'map(strings) | join(" ")' 2>&1)"
out="$("$BIN" --project diskjockey --urls --unclaimed)"
check "and combines with --unclaimed" "$GH/diskjockey/issues/165 $GH/diskjockey/issues/301" \
    "$(printf '%s' "$out" | jq -r 'join(" ")' 2>&1)"
"$BIN" --urls --prs >/dev/null 2>&1; rc=$?
check "--urls with --prs is refused" 2 "$rc"
"$BIN" --sort-by-title >/dev/null 2>&1; rc=$?
check "an unknown argument is refused" 2 "$rc"
AM_GITHUB_CACHE_TTL=soon "$BIN" --project diskjockey >/dev/null 2>&1; rc=$?
check "a TTL that is not a number of seconds is refused" 2 "$rc"

# ------------------------------------------------------ 3. pull requests
printf '301\t[{"state":"OPEN","url":"%s/diskjockey/pull/310"},{"state":"MERGED","url":"%s/diskjockey/pull/309"}]\n' \
    "$GH" "$GH" > "$sandbox/antimatter-studios-diskjockey.prs"
out="$("$BIN" --project diskjockey --prs)"; rc=$?
check "--prs exits 0" 0 "$rc"
check "an issue's pull requests come with their state" \
    "OPEN $GH/diskjockey/pull/310 MERGED $GH/diskjockey/pull/309" \
    "$(printf '%s' "$out" | jq -r '.[] | select(.number == 301) | [.prs[] | .state, .url] | join(" ")' 2>&1)"
check "an issue with none has an empty list, not a missing one" "[]" \
    "$(printf '%s' "$out" | jq -c '.[] | select(.number == 165) | .prs' 2>&1)"
check "and the entry still names its project" diskjockey "$(printf '%s' "$out" | jq -r '.[0].project')"

# ------------------------------------------------------------- 4. the cache
# Everything above ran with the default TTL into this sandbox's cache.
check "each project's answer is kept under XDG_CACHE_HOME, per repository" yes \
    "$(exists "$(cached diskjockey issues-open)")"
check "and --prs keeps its own entry beside it" yes "$(exists "$(cached diskjockey issues-open-prs)")"
check "a project with nothing open is kept too" yes "$(exists "$(cached rust-lzo1x issues-open)")"
: > "$AM_ISSUES_CALLS"
"$BIN" "${P[@]}" >/dev/null
"$BIN" --project diskjockey --prs >/dev/null
check "while the entries are fresh, asking again asks GitHub nothing" 0 "$(ncalls)"
"$BIN" "${P[@]}" --no-cache >/dev/null
check "--no-cache asks every project again" \
    "issues antimatter-studios-diskjockey issues antimatter-studios-rust-fs-ntfs issues antimatter-studios-rust-lzo1x" \
    "$(tr '\n' ' ' < "$AM_ISSUES_CALLS" | sed 's/ $//')"
: > "$AM_ISSUES_CALLS"
AM_GITHUB_CACHE_TTL=0 "$BIN" --project diskjockey >/dev/null
check "and so does a TTL of 0" 1 "$(ncalls)"

# ------------------------------------------------------- 5. a failed fetch
: > "$sandbox/antimatter-studios-rust-disk-partitions.fail"
out="$("$BIN" --project diskjockey --project rust-disk-partitions 2>"$sandbox/err")"; rc=$?
check "a failed fetch exits 4" 4 "$rc"
check "and names the project" 1 "$(grep -c 'FETCH FAILED  rust-disk-partitions$' "$sandbox/err")"
check "while the project that answered is still listed" "165 301 325" \
    "$(printf '%s' "$out" | jq -r '[.[].number | tostring] | join(" ")' 2>&1)"
check "and the failure is not cached" no "$(exists "$(cached rust-disk-partitions issues-open)")"
rm -f "$sandbox/antimatter-studios-rust-disk-partitions.fail"

: > "$sandbox/antimatter-studios-diskjockey.prsfail"
out="$("$BIN" --project diskjockey --prs --no-cache 2>"$sandbox/err")"; rc=$?
check "a failed pull request lookup exits 4" 4 "$rc"
check "and names the lookup" 1 "$(grep -c 'FETCH FAILED  diskjockey (pull requests)' "$sandbox/err")"
check "and leaves the issues' pull requests unknown, not empty" null \
    "$(printf '%s' "$out" | jq -c '.[] | select(.number == 301) | .prs' 2>&1)"
rm -f "$sandbox/antimatter-studios-diskjockey.prsfail"

# ------------------------------------------------------- 6. a rate limit
# Once GitHub limits the token every later request fails the same way, so the
# run stops at the first, prints no partial list, and caches nothing for it.
printf '%s\n' 'API rate limit exceeded for user ID 1. (HTTP 403)' \
    > "$sandbox/antimatter-studios-rust-disk-partitions.ratelimit"
: > "$AM_ISSUES_CALLS"
out="$("$BIN" --project diskjockey --project rust-disk-partitions --project rust-lzo1x --no-cache 2>"$sandbox/err")"; rc=$?
check "a rate limit exits 5" 5 "$rc"
check "and prints nothing on stdout" "" "$out"
check "and says where it stopped" 1 "$(grep -c 'stopped at rust-disk-partitions' "$sandbox/err")"
check "making no request after it" 2 "$(ncalls)"
check "and caching nothing for it" no "$(exists "$(cached rust-disk-partitions issues-open)")"
rm -f "$sandbox/antimatter-studios-rust-disk-partitions.ratelimit"

# ------------------------------------------------------ 7. nothing open
out="$("$BIN" --project rust-lzo1x --no-cache 2>"$sandbox/err")"; rc=$?
check "nothing open is an empty array, exit 0" "[] 0" "$(printf '%s' "$out" | jq -c . 2>&1) $rc"
check "and says so in words on stderr" 1 "$(grep -c 'no open issues' "$sandbox/err")"

# ------------------------------------------------- 8. the filters read gh
cat > "$sandbox/issues.json" <<'JSON'
[{"number":7,"created_at":"2026-09-01T10:00:00Z","html_url":"https://github.com/o/r/issues/7",
  "labels":[{"name":"bug"},{"name":"claimed"}],"title":"a \"quoted\"\ttitle"},
 {"number":8,"created_at":"2026-09-02T10:00:00Z","html_url":"https://github.com/o/r/pull/8",
  "labels":[],"title":"a pull request","pull_request":{"url":"x"}},
 {"number":9,"created_at":"2026-09-03T10:00:00Z","html_url":"https://github.com/o/r/issues/9",
  "labels":[],"title":"unlabelled"}]
JSON
rows="$(jq -r "$("$BIN" --print-jq)" < "$sandbox/issues.json" 2>&1)"
check "the issue filter drops pull requests" 2 "$(printf '%s\n' "$rows" | grep -c .)"
check "and leads each row with its time, claim, number and link" \
    "2026-09-01T10:00:00Z|1|7|https://github.com/o/r/issues/7" \
    "$(printf '%s\n' "$rows" | head -1 | cut -f1-4 | tr '\t' '|')"
check "an issue not labelled claimed is not claimed" 0 "$(printf '%s\n' "$rows" | sed -n 2p | cut -f2)"
check "and the entry is one line of JSON holding its fields" $'a "quoted"\ttitle|bug,claimed|7|2026-09-01T10:00:00Z|https://github.com/o/r/issues/7' \
    "$(printf '%s\n' "$rows" | head -1 | cut -f5 \
        | jq -r '[.title, (.labels | join(",")), (.number | tostring), .created, .url] | join("|")' 2>&1)"

cat > "$sandbox/prs.json" <<'JSON'
{"data":{"repository":{"issues":{"nodes":[
 {"number":5,
  "closedByPullRequestsReferences":{"nodes":[{"number":100,"url":"u/pull/100","state":"OPEN"}]},
  "timelineItems":{"nodes":[
    {"source":{"__typename":"PullRequest","number":100,"url":"u/pull/100","state":"OPEN"}},
    {"source":{"__typename":"Issue"}},
    {"source":{"__typename":"PullRequest","number":99,"url":"u/pull/99","state":"MERGED"}}]}},
 {"number":6,
  "closedByPullRequestsReferences":{"nodes":[]},
  "timelineItems":{"nodes":[{"source":{"__typename":"Issue"}}]}}]}}}}
JSON
prs="$(jq -r "$("$BIN" --print-pr-jq)" < "$sandbox/prs.json" 2>&1)"
check "closing and mentioning pull requests are merged, deduplicated, ordered, with their state" \
    "5|MERGED u/pull/99 OPEN u/pull/100" \
    "$(printf '%s\n' "$prs" | head -1 | cut -f1)|$(printf '%s\n' "$prs" | head -1 | cut -f2 \
        | jq -r '[.[] | .state, .url] | join(" ")' 2>&1)"
check "and an issue with none gets an empty list" "6|[]" "$(printf '%s\n' "$prs" | sed -n 2p | tr '\t' '|')"

finish
