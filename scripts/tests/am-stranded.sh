#!/usr/bin/env bash
#
# am-stranded.sh — the stranded-merge scan finds merged pull requests whose
# work never reached the default branch, and only those (#553).
#
# A pull request merged into a stacked base after that base had already
# landed is MERGED on GitHub and its issue reads as done, yet its work is
# on a branch nothing carries any further. On 2026-10-23 that was 87
# rust-fs-btrfs and 5 rust-fs-ext4 pull requests. The cases below are the
# shapes the scan has to tell apart: a direct strand, a strand two hops
# deep, a landing through an intermediate merge commit that main does
# reach, a strand a later pull request re-landed, and one an open pull
# request is restoring.
#
# Nothing here touches the network: AM_STRANDED_GH replaces gh with a stub
# that serves fixtures.
#
#   bash scripts/tests/am-stranded.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$REPO/scripts/am-stranded"
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

[ -x "$BIN" ] || fail "scripts/am-stranded is missing or not executable"

# THE STUB. Fixtures are files named after the slug with / as -:
#   <slug>.default    the default branch; absent means the repository fails
#   <slug>.merged     the merged pull requests, as `gh pr list --json` prints them
#   <slug>.open       the open pull requests, likewise
#   <slug>.reachable  merge commits the default branch reaches, one a line
# A compare of any other commit answers `diverged`.
cat > "$sandbox/gh" <<'STUB'
#!/usr/bin/env bash
F="$AM_STUB_FIXTURES"
key() { printf '%s' "$1" | tr '/' '-'; }
if [ "$1" = api ]; then
    path="${2#repos/}"
    case "$path" in
        */compare/*)
            slug="${path%%/compare/*}"; range="${path#*/compare/}"; sha="${range%%...*}"
            [ -f "$F/$(key "$slug").default" ] || exit 1
            if grep -qx "$sha" "$F/$(key "$slug").reachable" 2>/dev/null; then echo ahead; else echo diverged; fi
            exit 0 ;;
        *)
            [ -f "$F/$(key "$path").default" ] || exit 1
            cat "$F/$(key "$path").default"; exit 0 ;;
    esac
fi
if [ "$1" = pr ] && [ "$2" = list ]; then
    slug="$4"; state=""
    for ((i = 1; i <= $#; i++)); do [ "${!i}" = --state ] && { j=$((i + 1)); state="${!j}"; }; done
    case "$state" in
        merged) f="$F/$(key "$slug").merged" ;;
        open)   f="$F/$(key "$slug").open" ;;
        *) echo "stub gh: pr list without --state merged|open: $*" >&2; exit 3 ;;
    esac
    [ -f "$f" ] || exit 1
    cat "$f"; exit 0
fi
echo "stub gh: unexpected $*" >&2; exit 3
STUB
chmod +x "$sandbox/gh"
export AM_STRANDED_GH="$sandbox/gh"
export AM_STUB_FIXTURES="$sandbox"

# merged <number> <base> <head> <merge commit> <mergedAt> [body]
merged() {
    jq -cn --argjson n "$1" --arg base "$2" --arg head "$3" --arg oid "$4" --arg at "$5" --arg body "${6:-}" \
        '{number: $n, baseRefName: $base, headRefName: $head, mergeCommit: {oid: $oid}, mergedAt: $at, body: $body}'
}

S=antimatter-studios-rust-fs-btrfs
echo main > "$sandbox/$S.default"
{
    # 1. A direct strand: #2 merged into feat/a a day after feat/a's own
    #    pull request, #1, had squash-merged into main.
    merged 1 main feat/a m1 2026-10-01T00:00:00Z
    merged 2 feat/a feat/b m2 2026-10-02T00:00:00Z
    # 2. Two hops deep: #5 merged into feat/d; feat/d's pull request #4 then
    #    merged into feat/c, whose own pull request #3 had landed before.
    merged 3 main feat/c m3 2026-10-01T00:00:00Z
    merged 4 feat/c feat/d m4 2026-10-02T12:00:00Z
    merged 5 feat/d feat/e m5 2026-10-02T06:00:00Z
    # 3. Landed through an intermediate: #7 merged into feat/f before
    #    feat/f's pull request #6 squash-merged into main, carrying it.
    merged 6 main feat/f m6 2026-10-05T00:00:00Z
    merged 7 feat/f feat/g m7 2026-10-04T00:00:00Z
    # 4. Re-landed: #8 is stranded like #2, but #9, merged into main
    #    after it, names it.
    merged 8 feat/a feat/h m8 2026-10-03T00:00:00Z
    merged 9 main fix/reland m9 2026-10-06T00:00:00Z "Re-lands #8, which was merged into a base that had already landed."
    # 5. Covered: #10 and #15 are stranded like #2, and the open #11 names
    #    them, #15 inside a range.
    merged 10 feat/a feat/i m10 2026-10-03T00:00:00Z
    merged 15 feat/a feat/j m15 2026-10-03T00:00:00Z
    # 6. A queued stack layer: #12's base was feat/a, but the merge queue
    #    squash-merged it into main, so its merge commit is reachable.
    merged 12 feat/a feat/k m12 2026-10-07T00:00:00Z
    # 7. A mention by a pull request merged BEFORE the strand re-lands
    #    nothing: #13 named #14 a day before #14 was merged.
    merged 13 main docs/plan m13 2026-10-02T00:00:00Z "The plan: #14 comes next."
    merged 14 feat/a feat/l m14 2026-10-03T00:00:00Z
} | jq -s . > "$sandbox/$S.merged"
jq -n '[{number: 11, baseRefName: "main", body: "Restores #10, and #14 through #16 as well.\n\n#15 too."}]' > "$sandbox/$S.open"
printf '%s\n' m1 m3 m6 m9 m12 m13 > "$sandbox/$S.reachable"

# ------------------------------------------------------------ 1. the listing
out="$("$BIN" --repo rust-fs-btrfs 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "the listing exits 0" || fail "the listing exits $rc: $out"
contains "a direct strand is found" "antimatter-studios/rust-fs-btrfs	stranded	#2	" "$out"
contains "a direct strand names the landed base it was merged into" "#2 -> feat/a: #1 merged it into main before #2 was merged" "$out"
contains "a strand two hops deep is found" "antimatter-studios/rust-fs-btrfs	stranded	#5	" "$out"
contains "the two-hop strand shows the chain it followed" "#5 -> #4 -> feat/c: #3 merged it into main before #4 was merged" "$out"
contains "the hop that stranded it is found as well" "antimatter-studios/rust-fs-btrfs	stranded	#4	" "$out"
lacks "a landing through a reachable intermediate is not stranded" "	#7	" "$out"
contains "a re-landed strand is reported as re-landed" "antimatter-studios/rust-fs-btrfs	re-landed	#8	by #9" "$out"
lacks "a re-landed strand is not stranded" "stranded	#8	" "$out"
contains "a strand an open pull request names is covered" "antimatter-studios/rust-fs-btrfs	covered	#10	by open #11" "$out"
contains "a strand inside a named range is covered" "antimatter-studios/rust-fs-btrfs	covered	#15	by open #11" "$out"
lacks "a queued layer whose merge main reaches is not stranded" "	#12	" "$out"
contains "a mention made before the strand re-lands nothing" "antimatter-studios/rust-fs-btrfs	covered	#14	by open #11" "$out"
lacks "the earlier mention is not taken for a re-landing" "re-landed	#14	" "$out"
for n in 1 3 6 9 11 13; do
    lacks "#$n, merged into main, is not reported" "	#$n	" "$out"
done
contains "the summary counts each kind" "antimatter-studios/rust-fs-btrfs: 3 stranded, 1 re-landed, 3 covered" "$out"

# ------------------------------------------------------------ 2. the check
out="$("$BIN" --repo rust-fs-btrfs --check 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "--check fails while a strand is uncovered" || fail "--check exits $rc with uncovered strands"
contains "--check names how many are uncovered" "am-stranded: 3 stranded pull request(s) not covered by an open restoring pull request" "$out"

E=antimatter-studios-rust-fs-ext4
echo main > "$sandbox/$E.default"
{
    merged 1 main feat/a m1 2026-10-01T00:00:00Z
    merged 2 feat/a feat/b m2 2026-10-02T00:00:00Z
} | jq -s . > "$sandbox/$E.merged"
jq -n '[{number: 3, baseRefName: "main", body: "Restores #2."}]' > "$sandbox/$E.open"
echo m1 > "$sandbox/$E.reachable"
out="$("$BIN" --repo rust-fs-ext4 --check 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "--check passes when every strand is covered" || fail "--check exits $rc with every strand covered: $out"
contains "the covered strand is still listed" "antimatter-studios/rust-fs-ext4	covered	#2	by open #3" "$out"

# ------------------------------------------------- 3. what it cannot read
out="$("$BIN" --repo rust-fs-core 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "a repository it cannot read fails the run" || fail "an unreadable repository exits $rc"
contains "the unreadable repository is named" "antimatter-studios/rust-fs-core: could not be read" "$out"
X=antimatter-studios-rust-fs-xfs
echo main > "$sandbox/$X.default"
out="$("$BIN" --repo rust-fs-xfs 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "pull requests it cannot read fail the run" || fail "unreadable pull requests exit $rc"
contains "the repository whose pull requests failed is named" "antimatter-studios/rust-fs-xfs: its pull requests could not be read" "$out"
out="$("$BIN" --repo not-in-the-family 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "a repository outside the family is refused" || fail "an outside repository exits $rc"
out="$("$BIN" --bogus 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "an unknown argument is refused" || fail "an unknown argument exits $rc"

if [ "$fails" -gt 0 ]; then
    echo "am-stranded: $fails check(s) failed" >&2
    exit 1
fi
echo "am-stranded: all checks passed"
