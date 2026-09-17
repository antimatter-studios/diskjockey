#!/usr/bin/env bash
#
# am-prs.sh — who counts as external, and a failed fetch is not "none".
#
# Nothing here touches the network: AM_PRS_FETCH replaces the gh call.
#
#   bash scripts/tests/am-prs.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$REPO/scripts/am-prs"
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

# <slug-with-dashes>.rows is emitted verbatim; <slug-with-dashes>.fail fails.
cat > "$sandbox/fetch" <<'STUB'
#!/usr/bin/env bash
key="$(printf '%s' "$1" | tr '/' '-')"
[ -f "$AM_PRS_FIXTURES/$key.fail" ] && exit 1
[ -f "$AM_PRS_FIXTURES/$key.rows" ] && cat "$AM_PRS_FIXTURES/$key.rows"
exit 0
STUB
chmod +x "$sandbox/fetch"
export AM_PRS_FETCH="$sandbox/fetch"
export AM_PRS_FIXTURES="$sandbox"

row() { # number state association author-type login title
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f2026-09-01\x1fhttps://github.com/o/r/pull/%s\x1f%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$1" "$6"
}
f="$sandbox/antimatter-studios-diskjockey.rows"
row 1 MERGED OWNER                  User christhomas "by the owner"                 > "$f"
row 2 OPEN   MEMBER                 User christhomas "by a member"                 >> "$f"
row 3 OPEN   COLLABORATOR           User friend      "by a collaborator"           >> "$f"
row 4 OPEN   NONE                   Bot  dependabot  "by a bot"                    >> "$f"
row 5 OPEN   FIRST_TIME_CONTRIBUTOR User newcomer    "by a first-time contributor" >> "$f"
row 6 CLOSED CONTRIBUTOR            User returner    "by a contributor"            >> "$f"
row 7 MERGED NONE                   User ghost       "by a deleted account"        >> "$f"

# ------------------------------------------------------------ 1. everything
out="$("$BIN" --project diskjockey 2>&1)"; rc=$?
check "the list exits 0" 0 "$rc"
check "every pull request is listed" 7 "$(printf '%s\n' "$out" | grep -c '^diskjockey ')"
contains "and counted" "TOTAL — 7 pull requests across 1 project(s)" "$out"

# ------------------------------------------------------ 2. who is external
tsv="$("$BIN" --project diskjockey --external --tsv)"
check "external is contributors, first-timers and deleted accounts" "5 6 7" \
    "$(printf '%s\n' "$tsv" | awk -F'\t' 'NR > 1 {print $2}' | tr '\n' ' ' | sed 's/ $//')"

# ---------------------------------------------------------------- 3. state
tsv="$("$BIN" --project diskjockey --external --state open --tsv)"
check "state and origin combine" "5" "$(printf '%s\n' "$tsv" | awk -F'\t' 'NR > 1 {print $2}')"
"$BIN" --state draft >/dev/null 2>&1; rc=$?
check "an unknown state is refused" 2 "$rc"

# ------------------------------------------------------- 4. a failed fetch
: > "$sandbox/antimatter-studios-rust-partitions.fail"
out="$("$BIN" --project diskjockey --project rust-partitions 2>&1)"; rc=$?
check "a failed fetch exits 4" 4 "$rc"
contains "and names the project" "FETCH FAILED  rust-partitions" "$out"
contains "while the readable project still lists" "by a contributor" "$out"
rm -f "$sandbox/antimatter-studios-rust-partitions.fail"

# --------------------------------------------------------- 5. nothing found
out="$("$BIN" --project rust-lzo1x 2>&1)"; rc=$?
check "no pull requests exits 0" 0 "$rc"
contains "and says so in words" "no pull requests in any of the 1 project(s)" "$out"

# ------------------------------------------------- 6. the filter reads gh
if command -v jq >/dev/null 2>&1; then
    cat > "$sandbox/prs.json" <<'JSON'
{"data":{"repository":{"pullRequests":{"nodes":[
 {"number":9,"state":"OPEN","authorAssociation":"NONE","createdAt":"2026-09-01T10:00:00Z",
  "title":"","url":"u/9","author":null}]}}}}
JSON
    got="$(jq -r "$("$BIN" --print-jq)" < "$sandbox/prs.json" | tr '\037' '|')"
    check "a deleted author and an empty title still fill every field" \
        "9|OPEN|NONE|User|ghost|2026-09-01|u/9|(no title)" "$got"
else
    echo "ok — jq absent, filter check skipped (stated, not silent)"
fi

if [ "$fails" -eq 0 ]; then
    echo "am-prs: all checks passed"
else
    echo "am-prs: $fails check(s) failed" >&2
fi
exit $(( fails > 0 ))
