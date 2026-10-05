#!/usr/bin/env bash
# Every commit on main gets a whole CI run.
#
# With `cancel-in-progress: true` for every event, a merge cancelled the run
# of the merge before it, and the required checks went red on jobs that were
# cancelled, not broken: a red mark on a commit nobody finished testing.
# GitHub also keeps one pending run per concurrency group, so a third merge
# cancels a second one still queued even with cancelling off. So a push is a
# group of its own, keyed by its commit, and only a pull request's superseded
# run is cancelled. release.yml is tag-driven and never cancels; it is not
# checked here.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }

for wf in ci.yml cli-pipe.yml; do
    block="$(awk '/^concurrency:/{f=1;next} f&&/^[^ ]/{exit} f{sub(/^[ \t]+/,""); print}' "$REPO/.github/workflows/$wf")"
    if grep -qxF "cancel-in-progress: \${{ github.event_name == 'pull_request' }}" <<<"$block"; then
        ok "$wf cancels only a pull request's superseded run"
    else
        bad "$wf cancels a run that is not a pull request's: $(grep cancel <<<"$block")"
    fi
    if grep -q 'github.sha' <<<"$(grep '^group:' <<<"$block")"; then
        ok "$wf gives each push a concurrency group of its own"
    else
        bad "$wf's pushes share a concurrency group: $(grep '^group:' <<<"$block")"
    fi
done

[ "$fails" -eq 0 ] || exit 1
echo "ci-concurrency: all checks passed"
