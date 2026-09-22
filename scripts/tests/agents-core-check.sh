#!/usr/bin/env bash
# scripts/agents-core-check.sh must REJECT a modified, stale or absent shared
# block, not merely accept a good one. A gate that cannot fail is
# indistinguishable from no gate, which is the whole reason the block carries a
# digest rather than a version number somebody remembers to bump.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || exit 1

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }

BAK="$(mktemp)"; cp AGENTS.md "$BAK"
restore() { cp "$BAK" AGENTS.md; }
trap 'restore; rm -f "$BAK"' EXIT

# want=zero|nonzero. Runs the checker WITHOUT a pipe: `$?` after a pipe is the
# status of the pipe's last command, which is how a suite of these came to
# report every failure as a pass.
expect() {
    local what="$1" want="$2"
    scripts/agents-core-check.sh >/dev/null 2>&1
    local rc=$?
    case "$want" in
        zero)    [ "$rc" -eq 0 ] && ok "$what" || bad "$what: expected exit 0, got $rc" ;;
        nonzero) [ "$rc" -ne 0 ] && ok "$what" || bad "$what: expected non-zero, got $rc" ;;
    esac
}

expect "the committed AGENTS.md passes" zero

# One character inside the block is enough: the digest covers content, so a
# trailing space is as much a change as a rewritten paragraph.
sed -i'' -e '0,/^## Claiming work$/s//## Claiming work /' AGENTS.md
expect "a modified block is refused" nonzero
restore

sed -i'' -e '/BEGIN SHARED BLOCK/d' AGENTS.md
expect "a missing BEGIN marker is refused" nonzero
restore

sed -i'' -e '/END SHARED BLOCK/d' AGENTS.md
expect "a missing END marker is refused" nonzero
restore

mv AGENTS.md "$BAK.hidden"
expect "an absent AGENTS.md is refused" nonzero
mv "$BAK.hidden" AGENTS.md

expect "the file is intact again afterwards" zero

[ "$fails" -eq 0 ] || exit 1
echo "agents-core-check: all checks passed"
