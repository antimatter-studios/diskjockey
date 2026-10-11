#!/usr/bin/env bash
#
# am-branch-reap.sh — the branch reaper deletes only what it can prove is
# finished, and checks again before it does.
#
# am-branch-reap is a DELETION tool, and the one thing it must never do is
# delete a branch somebody still needs: a stacked pull request's base, a
# branch that moved after its merge, one merged a minute ago, one whose
# pull request was closed rather than merged. Each case below is one of
# those, plus the plain one it exists for.
#
# Nothing here touches the network: AM_BRANCH_REAP_GH replaces gh with a
# stub that serves fixtures and records every delete it is asked for.
#
#   bash scripts/tests/am-branch-reap.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$REPO/scripts/am-branch-reap"
fails=0
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

ok()   { echo "ok — $1"; }
fail() { echo "FAIL — $1" >&2; fails=$((fails + 1)); }
contains() { # contains <what> <needle> <haystack>
    case "$3" in *"$2"*) ok "$1" ;; *) fail "$1: [$2] not in output" ;; esac
}
lacks() { # lacks <what> <needle> <haystack>
    case "$3" in *"$2"*) fail "$1: [$2] is in the output" ;; *) ok "$1" ;; esac
}

# THE STUB. Fixtures are files named after the slug with / as -:
#   <slug>.default   the default branch; absent means the repository fails
#   <slug>.branches  name<TAB>sha<TAB>protected, as the --jq renders it
#   <slug>.prs       number state head oid base mergedAt cross, tab-separated
#   <slug>.tip.<b>   the tip the re-check sees, when it differs (/ in b as _)
#   <slug>.kids.<b>  open pull requests based on b at the re-check
#   <slug>.refuse.<b> the delete fails
# Every DELETE is appended to $AM_STUB_CALLS.
cat > "$sandbox/gh" <<'STUB'
#!/usr/bin/env bash
F="$AM_STUB_FIXTURES"
key() { printf '%s' "$1" | tr '/' '-'; }
enc() { printf '%s' "$1" | tr '/' '_'; }
if [ "$1" = api ] && [ "$2" = -X ] && [ "$3" = DELETE ]; then
    path="${4#repos/}"; slug="${path%%/git/refs/heads/*}"; b="${path#*/git/refs/heads/}"
    echo "DELETE $slug $b" >> "$AM_STUB_CALLS"
    [ -f "$F/$(key "$slug").refuse.$(enc "$b")" ] && exit 1
    exit 0
fi
if [ "$1" = api ] && [ "$2" = --paginate ]; then
    slug="${3#repos/}"; slug="${slug%%/branches*}"
    cat "$F/$(key "$slug").branches"; exit 0
fi
if [ "$1" = api ]; then
    path="${2#repos/}"
    case "$path" in
        */git/ref/heads/*)
            slug="${path%%/git/ref/heads/*}"; b="${path#*/git/ref/heads/}"
            t="$F/$(key "$slug").tip.$(enc "$b")"
            if [ -f "$t" ]; then cat "$t"; else awk -F'\t' -v b="$b" '$1==b{print $2}' "$F/$(key "$slug").branches"; fi
            exit 0 ;;
        *)
            [ -f "$F/$(key "$path").default" ] || exit 1
            cat "$F/$(key "$path").default"; exit 0 ;;
    esac
fi
if [ "$1" = pr ] && [ "$2" = list ]; then
    slug="$4"; base=""
    for ((i = 1; i <= $#; i++)); do [ "${!i}" = --base ] && { j=$((i + 1)); base="${!j}"; }; done
    if [ -n "$base" ]; then
        k="$F/$(key "$slug").kids.$(enc "$base")"
        if [ -f "$k" ]; then cat "$k"; else echo 0; fi
        exit 0
    fi
    cat "$F/$(key "$slug").prs"; exit 0
fi
echo "stub gh: unexpected $*" >&2; exit 3
STUB
chmod +x "$sandbox/gh"
export AM_BRANCH_REAP_GH="$sandbox/gh"
export AM_STUB_FIXTURES="$sandbox"
export AM_STUB_CALLS="$sandbox/calls"
export AM_BRANCH_REAP_LOG="$sandbox/deleted.tsv"
# Merges at or before this are old enough; one after it is too recent.
export AM_BRANCH_REAP_CUTOFF="2026-10-11T10:00:00Z"

S=antimatter-studios-rust-fs-btrfs
T=$'\t'
printf '%s\n' main > "$sandbox/$S.default"
{
    echo "main${T}m000${T}true"
    echo "feat/done${T}a111${T}false"          # merged at its tip, long ago: goes
    echo "feat/moved${T}b222${T}false"         # merged, then pushed to
    echo "feat/open${T}c333${T}false"          # its pull request is open
    echo "feat/base${T}d444${T}false"          # merged, but a stacked PR is based on it
    echo "feat/fresh${T}e555${T}false"         # merged a minute ago
    echo "feat/closed${T}f666${T}false"        # its pull request was closed, not merged
    echo "feat/nopr${T}g777${T}false"          # never had a pull request
    echo "release/keep${T}h888${T}true"        # protected
    echo "gh-readonly-queue/main/pr-9-x${T}i999${T}false"
    echo "wip/rescued${T}j000${T}false"
    echo "feat/fork${T}k111${T}false"          # a fork's merged PR shares its name and commit
    echo "feat/again${T}l222${T}false"         # merged once, then reopened as a new PR
} > "$sandbox/$S.branches"
{
    echo "1${T}MERGED${T}feat/done${T}a111${T}main${T}2026-10-01T00:00:00Z${T}false"
    echo "2${T}MERGED${T}feat/moved${T}b000${T}main${T}2026-10-01T00:00:00Z${T}false"
    echo "3${T}OPEN${T}feat/open${T}c333${T}main${T}-${T}false"
    echo "4${T}MERGED${T}feat/base${T}d444${T}main${T}2026-10-01T00:00:00Z${T}false"
    echo "5${T}OPEN${T}feat/child${T}zzzz${T}feat/base${T}-${T}false"
    echo "6${T}MERGED${T}feat/fresh${T}e555${T}main${T}2026-10-11T11:00:00Z${T}false"
    echo "7${T}CLOSED${T}feat/closed${T}f666${T}main${T}-${T}false"
    echo "8${T}MERGED${T}feat/fork${T}k111${T}main${T}2026-10-01T00:00:00Z${T}true"
    echo "9${T}MERGED${T}feat/again${T}l222${T}main${T}2026-10-01T00:00:00Z${T}false"
    echo "10${T}OPEN${T}feat/again${T}l222${T}main${T}-${T}false"
} > "$sandbox/$S.prs"

# ------------------------------------------------------------ 1. the dry run
: > "$AM_STUB_CALLS"
out="$("$BIN" --repo rust-fs-btrfs 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "the dry run exits 0" || fail "the dry run exits $rc"
contains "a branch at its merged commit would go" "would delete	feat/done	merged as #1" "$out"
[ -s "$AM_STUB_CALLS" ] && fail "the dry run asked for a delete: $(cat "$AM_STUB_CALLS")" || ok "the dry run deletes nothing"
contains "a branch pushed to after its merge is kept for a person" "keep	feat/moved	not at the commit any of its pull requests merged" "$out"
contains "a closed pull request's branch is kept for a person" "keep	feat/closed	not at the commit" "$out"
contains "a branch with no pull request is kept for a person" "keep	feat/nopr	no pull request merged it" "$out"
contains "a fork's merge is no evidence about this repository's branch" "keep	feat/fork	no pull request merged it" "$out"
for b in main feat/open feat/base feat/fresh release/keep gh-readonly-queue/main/pr-9-x wip/rescued feat/again; do
    lacks "$b is not deleted" "delete	$b	" "$out"
done
contains "the summary counts one deleted and four for a person" "would delete 1, kept 12 (4 for a person)" "$out"

# ------------------------------------------------------------ 2. applied
: > "$AM_STUB_CALLS"
out="$("$BIN" --repo rust-fs-btrfs --apply 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "the applied run exits 0" || fail "the applied run exits $rc"
calls="$(cat "$AM_STUB_CALLS")"
[ "$calls" = "DELETE antimatter-studios/rust-fs-btrfs feat/done" ] \
    && ok "exactly the finished branch is deleted" || fail "deletes asked for: [$calls]"
log="$(cat "$AM_BRANCH_REAP_LOG" 2>/dev/null)"
contains "the deletion is recorded with its commit and pull request" "antimatter-studios/rust-fs-btrfs	feat/done	a111	#1" "$log"

# ------------------------------------------------- 3. it changed while we ran
: > "$AM_STUB_CALLS"; : > "$AM_BRANCH_REAP_LOG"
echo "a999" > "$sandbox/$S.tip.feat_done"
out="$("$BIN" --repo rust-fs-btrfs --apply 2>&1)"
contains "a branch pushed to since the listing is kept" "keep	feat/done	changed while this ran" "$out"
[ -s "$AM_STUB_CALLS" ] && fail "a moved branch was deleted" || ok "a moved branch is not deleted"
[ -s "$AM_BRANCH_REAP_LOG" ] && fail "a kept branch was logged as deleted" || ok "nothing is logged for a kept branch"
rm -f "$sandbox/$S.tip.feat_done"

echo 1 > "$sandbox/$S.kids.feat_done"
out="$("$BIN" --repo rust-fs-btrfs --apply 2>&1)"
contains "a branch a pull request was just based on is kept" "keep	feat/done	changed while this ran" "$out"
[ -s "$AM_STUB_CALLS" ] && fail "a new base was deleted" || ok "a new base is not deleted"
rm -f "$sandbox/$S.kids.feat_done"

touch "$sandbox/$S.refuse.feat_done"
out="$("$BIN" --repo rust-fs-btrfs --apply 2>&1)"
contains "a refused delete is reported, not counted" "keep	feat/done	the delete was refused" "$out"
contains "a refused delete is not counted as deleted" "deleted 0," "$out"
rm -f "$sandbox/$S.refuse.feat_done"

# ------------------------------------------------- 4. the grace period moves
: > "$AM_STUB_CALLS"
out="$(AM_BRANCH_REAP_CUTOFF=2026-10-11T12:00:00Z "$BIN" --repo rust-fs-btrfs 2>&1)"
contains "a merge older than the cutoff is old enough" "would delete	feat/fresh	merged as #6" "$out"

# ------------------------------------------------- 5. what it cannot read
out="$("$BIN" --repo rust-fs-core 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "a repository it cannot read fails the run" || fail "an unreadable repository exits $rc"
contains "the unreadable repository is named" "antimatter-studios/rust-fs-core: could not be read" "$out"
out="$("$BIN" --repo not-in-the-family 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "a repository outside the family is refused" || fail "an outside repository exits $rc"
out="$(AM_BRANCH_REAP_GRACE_MINS=soon "$BIN" --repo rust-fs-btrfs 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "a grace period that is not minutes is refused" || fail "a bad grace period exits $rc"

if [ "$fails" -gt 0 ]; then
    echo "am-branch-reap: $fails check(s) failed" >&2
    exit 1
fi
echo "am-branch-reap: all checks passed"
