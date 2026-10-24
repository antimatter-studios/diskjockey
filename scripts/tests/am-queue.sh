#!/usr/bin/env bash
#
# am-queue.sh — one request for the whole constellation, a fallback that
# names what it could not read, and a five-minute cache (#560).
#
# Nothing here touches the network: AM_QUEUE_FETCH replaces the gh call.
#
#   bash scripts/tests/am-queue.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$REPO/scripts/am-queue"
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
absent() { # absent <what> <needle> <haystack>
    case "$3" in
        *"$2"*) echo "FAIL — $1: [$2] in output" >&2; fails=$((fails + 1)) ;;
        *) echo "ok — $1" ;;
    esac
}

# The stub is called with every slug one request asks about. Each call is one
# line of AM_QUEUE_CALLS: its slugs, space-separated. A slug with a
# <slug-with-dashes>.ratelimit fixture fails the call with that message, one
# with a .fail fixture fails it plainly -- so a combined request fails as a
# whole, and only that slug's own request fails after it. Otherwise each
# slug's .rows fixture is printed, slug first.
cat > "$sandbox/fetch" <<'STUB'
#!/usr/bin/env bash
[ -z "${AM_QUEUE_CALLS:-}" ] || printf '%s\n' "$*" >> "$AM_QUEUE_CALLS"
for slug in "$@"; do
    key="$(printf '%s' "$slug" | tr '/' '-')"
    [ ! -f "$AM_QUEUE_FIXTURES/$key.ratelimit" ] || { cat "$AM_QUEUE_FIXTURES/$key.ratelimit" >&2; exit 1; }
    [ ! -f "$AM_QUEUE_FIXTURES/$key.fail" ] || exit 1
done
for slug in "$@"; do
    key="$(printf '%s' "$slug" | tr '/' '-')"
    [ ! -f "$AM_QUEUE_FIXTURES/$key.rows" ] || \
        awk -v s="$slug" '{ print s "\037" $0 }' "$AM_QUEUE_FIXTURES/$key.rows"
done
exit 0
STUB
chmod +x "$sandbox/fetch"
export AM_QUEUE_FETCH="$sandbox/fetch"
export AM_QUEUE_FIXTURES="$sandbox"
# The cache lives in this run's sandbox, and until its own section below
# every call asks: a TTL of 0 reads no entry.
export XDG_CACHE_HOME="$sandbox/cache"
export AM_GITHUB_CACHE_TTL=0
calls="$sandbox/calls"
export AM_QUEUE_CALLS="$calls"
ncalls() { wc -l < "$calls" | tr -d ' '; }

row() { # position state enqueued number title
    printf '%s\x1f%s\x1f%s\x1f%s\x1fhttps://github.com/o/r/pull/%s\x1f%s\n' \
        "$1" "$2" "$3" "$4" "$4" "$5"
}
row 1 AWAITING_CHECKS 2026-10-24T14:01 559 "the loop starts" >  "$sandbox/antimatter-studios-diskjockey.rows"
row 2 QUEUED          2026-10-24T14:05 561 "a second change" >> "$sandbox/antimatter-studios-diskjockey.rows"
row 1 MERGEABLE       2026-10-24T13:46 403 "core cites"      >  "$sandbox/antimatter-studios-rust-fs-core.rows"
THREE=(--project diskjockey --project rust-fs-core --project rust-lzo1x)

# ------------------------------------------------- 1. one request, one table
: > "$calls"
out="$("$BIN" "${THREE[@]}" 2>&1)"; rc=$?
check "the list exits 0" 0 "$rc"
check "three projects are one request" 1 "$(ncalls)"
check "which asks about all three" \
    "antimatter-studios/diskjockey antimatter-studios/rust-fs-core antimatter-studios/rust-lzo1x" \
    "$(head -1 "$calls")"
check "every queued pull request is listed" 3 "$(printf '%s\n' "$out" | grep -cE '^(diskjockey|rust-fs-core) ')"
contains "with its position and state" "AWAITING_CHECKS" "$out"
contains "and counted" "TOTAL — 3 queued pull requests across 2 project(s)" "$out"
tsv="$("$BIN" "${THREE[@]}" --tsv)"
check "--tsv has a header" "project	position	state	queued	pr	url	title" "$(printf '%s\n' "$tsv" | head -1)"
check "and one row per queued pull request, in queue order" "559 561 403" \
    "$(printf '%s\n' "$tsv" | awk -F'\t' 'NR > 1 {print $5}' | tr '\n' ' ' | sed 's/ $//')"

# ------------------------------------------------------------ 2. nothing
out="$("$BIN" --project rust-lzo1x 2>&1)"; rc=$?
check "an empty queue exits 0" 0 "$rc"
contains "and says so in words" "no pull request is queued in any of the 1 project(s)" "$out"
"$BIN" --project no-such-project >/dev/null 2>&1; rc=$?
check "a project that is not in the constellation is refused" 2 "$rc"
"$BIN" --sideways >/dev/null 2>&1; rc=$?
check "an unknown argument is refused" 2 "$rc"

# ----------------------------------------------- 3. a failed combined request
# One unreadable repository fails the combined request; each repository is
# then asked on its own, so it alone is FETCH FAILED.
: > "$sandbox/antimatter-studios-rust-fs-core.fail"
: > "$calls"
out="$("$BIN" "${THREE[@]}" 2>&1)"; rc=$?
check "a failed fetch exits 4" 4 "$rc"
contains "and names the project" "FETCH FAILED  rust-fs-core" "$out"
contains "while the readable project still lists" "the loop starts" "$out"
check "after the combined request, each project is asked on its own" 4 "$(ncalls)"
rm -f "$sandbox/antimatter-studios-rust-fs-core.fail"

# ------------------------------------------------------------ 4. rate limit
# A token-wide limit stops the run: no table, and no request per project.
for message in 'API rate limit exceeded (HTTP 403)' \
               'You have exceeded a secondary rate limit (HTTP 403)'; do
    printf '%s\n' "$message" > "$sandbox/antimatter-studios-rust-fs-core.ratelimit"
    : > "$calls"
    out="$("$BIN" "${THREE[@]}" 2>&1)"; rc=$?
    check "a rate limit exits 5 [$message]" 5 "$rc"
    check "after one request [$message]" 1 "$(ncalls)"
    absent "and prints no table [$message]" "PROJECT" "$out"
done
rm -f "$sandbox/antimatter-studios-rust-fs-core.ratelimit"

# ----------------------------------------------------------- 5. the filter
if command -v jq >/dev/null 2>&1; then
    cat > "$sandbox/queue.json" <<'JSON'
{"data":{
 "r0":{"mergeQueue":{"entries":{"nodes":[
   {"position":1,"state":"AWAITING_CHECKS","enqueuedAt":"2026-10-24T14:01:09Z",
    "pullRequest":{"number":559,"title":"","url":"u/559"}}]}}},
 "r1":{"mergeQueue":null}}}
JSON
    got="$(jq -r "$("$BIN" --print-jq)" < "$sandbox/queue.json" | tr '\037' '|')"
    check "the filter tags each entry with its alias, and fills an empty title" \
        "r0|1|AWAITING_CHECKS|2026-10-24T14:01|559|u/559|(no title)" "$got"
else
    echo "FAIL — jq is needed to check the filter; install jq" >&2
    fails=$((fails + 1))
fi

# ------------------------------------------------------------- 6. the cache
# Each repository's answer is kept under `merge-queue`; only the stale ones
# are asked about, still in one request; the default TTL is 300 seconds.
unset AM_GITHUB_CACHE_TTL
rm -rf "$XDG_CACHE_HOME"
cached() { printf '%s/am/github/antimatter-studios/%s/merge-queue' "$XDG_CACHE_HOME" "$1"; }
exists() { if [ -e "$1" ]; then echo yes; else echo no; fi; }
age() { # age <file> <seconds>: date the file that many seconds ago
    local t=$(( $(date +%s) - $2 ))
    touch -d "@$t" "$1" 2>/dev/null || touch -t "$(date -r "$t" +%Y%m%d%H%M.%S)" "$1"
}
: > "$calls"
"$BIN" "${THREE[@]}" >/dev/null
check "the first call asks, once" 1 "$(ncalls)"
check "and keeps each repository's answer" "yes yes yes" \
    "$(exists "$(cached diskjockey)") $(exists "$(cached rust-fs-core)") $(exists "$(cached rust-lzo1x)")"
: > "$calls"
tsv="$("$BIN" "${THREE[@]}" --tsv)"
check "while they are fresh, asking again asks nothing" 0 "$(ncalls)"
check "and the kept answers list as fresh ones do" "559 561 403" \
    "$(printf '%s\n' "$tsv" | awk -F'\t' 'NR > 1 {print $5}' | tr '\n' ' ' | sed 's/ $//')"
age "$(cached rust-fs-core)" 299
"$BIN" "${THREE[@]}" >/dev/null
check "an answer 299 seconds old is still fresh" 0 "$(ncalls)"
age "$(cached rust-fs-core)" 301
age "$(cached rust-lzo1x)" 301
"$BIN" "${THREE[@]}" >/dev/null
check "past 300 seconds the stale ones are asked about, in one request" \
    "antimatter-studios/rust-fs-core antimatter-studios/rust-lzo1x" "$(cat "$calls")"
: > "$calls"
"$BIN" "${THREE[@]}" --no-cache >/dev/null
check "--no-cache asks about all of them" 1 "$(ncalls)"
: > "$calls"
AM_GITHUB_CACHE_TTL=0 "$BIN" "${THREE[@]}" >/dev/null
check "and so does a TTL of 0" 1 "$(ncalls)"
AM_GITHUB_CACHE_TTL=soon "$BIN" --project diskjockey >/dev/null 2>&1; rc=$?
check "a TTL that is not a number of seconds is refused" 2 "$rc"
rm -rf "$XDG_CACHE_HOME"
: > "$sandbox/antimatter-studios-rust-fs-core.fail"
"$BIN" --project rust-fs-core >/dev/null 2>&1; rc=$?
check "a failed fetch still exits 4" 4 "$rc"
check "and keeps no entry" no "$(exists "$(cached rust-fs-core)")"
rm -f "$sandbox/antimatter-studios-rust-fs-core.fail"
: > "$calls"
"$BIN" --project rust-fs-core >/dev/null 2>&1
check "so the next call asks again" 1 "$(ncalls)"

if [ "$fails" -eq 0 ]; then
    echo "am-queue: all checks passed"
else
    echo "am-queue: $fails check(s) failed" >&2
fi
exit $(( fails > 0 ))
