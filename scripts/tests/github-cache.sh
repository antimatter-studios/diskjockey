#!/usr/bin/env bash
#
# github-cache.sh — the per-repository cache of GitHub answers keeps whole,
# successful answers, for as long as it was asked to, and nothing else.
#
# A cached failure would read as "nothing there" for the whole TTL, and a
# half-written answer as a short list: the plausible-output failure the
# inventory tools refuse everywhere else (see am-overview's header). Nothing
# here touches the network: the fetch is a stub that logs each call, and the
# cache lives in this run's sandbox (#544).
#
#   bash scripts/tests/github-cache.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
        echo "github-cache: all checks passed"
    else
        echo "github-cache: $fails check(s) failed"
    fi
    exit $(( fails > 0 ))
}

if [ ! -f "$REPO/scripts/github-cache.sh" ]; then
    check "scripts/github-cache.sh exists" yes no
    finish
fi
# shellcheck source=../github-cache.sh
. "$REPO/scripts/github-cache.sh"

export XDG_CACHE_HOME="$sandbox/cache"
export HOME="$sandbox/home"
calls="$sandbox/calls"
: > "$calls"
# The fetch: logs the call, prints $ANSWER, writes $FETCH_ERR to stderr and
# exits $FETCH_RC.
fetch() {
    echo "$*" >> "$calls"
    [ -z "${FETCH_ERR:-}" ] || echo "$FETCH_ERR" >&2
    printf '%s\n' "${ANSWER:-}"
    return "${FETCH_RC:-0}"
}
ncalls() { wc -l < "$calls" | tr -d ' '; }
exists() { if [ -e "$1" ]; then echo yes; else echo no; fi; }
SLUG=antimatter-studios/diskjockey

# ---------------------------------------------------------------- 1. where
check "an entry lives under XDG_CACHE_HOME, per repository and key" \
    "$sandbox/cache/am/github/antimatter-studios/diskjockey/issues-open" \
    "$(github_cache_path "$SLUG" issues-open)"
check "a relative XDG_CACHE_HOME is ignored, as the base directory spec requires" \
    "$sandbox/home/.cache/am/github/antimatter-studios/diskjockey/issues-open" \
    "$(XDG_CACHE_HOME=relative/cache github_cache_path "$SLUG" issues-open)"
check "an unset XDG_CACHE_HOME falls back to ~/.cache" \
    "$sandbox/home/.cache/am/github/antimatter-studios/diskjockey/issues-open" \
    "$(unset XDG_CACHE_HOME; github_cache_path "$SLUG" issues-open)"

# --------------------------------------------------------- 2. kept, reused
entry="$(github_cache_path "$SLUG" issues-open)"
out="$(ANSWER=first github_cached "$SLUG" issues-open 600 fetch "$SLUG")"; rc=$?
check "a first ask exits as the fetch did" 0 "$rc"
check "and prints the fetch's answer" first "$out"
check "and asks once" 1 "$(ncalls)"
check "and keeps the answer" first "$(cat "$entry" 2>/dev/null)"
out="$(ANSWER=second github_cached "$SLUG" issues-open 600 fetch "$SLUG")"
check "a fresh entry answers the next ask" first "$out"
check "without asking again" 1 "$(ncalls)"

# ------------------------------------------------- 3. one entry a question
out="$(ANSWER=prs github_cached "$SLUG" issues-open-prs 600 fetch "$SLUG")"
check "another key is another entry, so it asks" "prs 2" "$out $(ncalls)"
out="$(ANSWER=ntfs github_cached antimatter-studios/rust-fs-ntfs issues-open 600 fetch x)"
check "another repository is another entry, so it asks" "ntfs 3" "$out $(ncalls)"
check "and the first entry is untouched" first "$(cat "$entry")"

# ------------------------------------------------------------ 4. freshness
: > "$calls"
out="$(ANSWER=refreshed github_cached "$SLUG" issues-open 0 fetch "$SLUG")"
check "a TTL of 0 always asks" "refreshed 1" "$out $(ncalls)"
check "and still refreshes the entry" refreshed "$(cat "$entry")"
touch -t 202001010000 "$entry"
out="$(ANSWER=again github_cached "$SLUG" issues-open 600 fetch "$SLUG")"
check "an entry older than its TTL is asked again" "again 2" "$out $(ncalls)"

# ---------------------------------------------- 5. a failure is never kept
: > "$calls"
before="$(cat "$entry")"
touch -t 202001010000 "$entry"
err="$( { ANSWER=partial FETCH_RC=3 FETCH_ERR="gh: HTTP 502" \
    github_cached "$SLUG" issues-open 600 fetch "$SLUG" >/dev/null; } 2>&1)"; rc=$?
check "a failed fetch's exit status passes through" 3 "$rc"
check "and so does its stderr" "gh: HTTP 502" "$err"
check "and the stale entry it would have replaced stays as it was" "$before" "$(cat "$entry")"
out="$(ANSWER=recovered github_cached "$SLUG" issues-open 600 fetch "$SLUG")"
check "so the next ask asks again" "recovered 2" "$out $(ncalls)"
ANSWER=x FETCH_RC=1 github_cached "$SLUG" never-answered 600 fetch "$SLUG" >/dev/null 2>&1
check "a failure on a new key writes no entry" no "$(exists "$(github_cache_path "$SLUG" never-answered)")"
check "and no temporary file is left beside the entries" "" \
    "$(ls -A "$(dirname "$entry")" | grep -v -x -e issues-open -e issues-open-prs)"

# ---------------------------------------------- 6. no cache is not no answer
: > "$sandbox/not-a-directory"
out="$(XDG_CACHE_HOME="$sandbox/not-a-directory" ANSWER=uncached \
    github_cached "$SLUG" issues-open 600 fetch "$SLUG" 2>/dev/null)"; rc=$?
check "a cache that cannot be written still answers" "uncached 0" "$out $rc"

# ------------------------------------------- 7. what cannot name an entry
for bad in "../escape" "owner/repo/extra" "/abs" "owner/" "noslash" "./repo" "owner/.." ""; do
    : > "$calls"
    github_cached "$bad" issues-open 600 fetch x >/dev/null 2>&1; rc=$?
    check "repository '$bad' is refused before any fetch" "2 0" "$rc $(ncalls)"
done
for bad in "../x" "a/b" "" ".hidden" "sp ace"; do
    : > "$calls"
    github_cached "$SLUG" "$bad" 600 fetch x >/dev/null 2>&1; rc=$?
    check "key '$bad' is refused before any fetch" "2 0" "$rc $(ncalls)"
done
: > "$calls"
github_cached "$SLUG" issues-open soon fetch x >/dev/null 2>&1; rc=$?
check "a TTL that is not a number of seconds is refused" "2 0" "$rc $(ncalls)"

finish
