#!/usr/bin/env bash
#
# red-runs-uncancelled.sh — a red: pull request's run is never cancelled by
# the push that adds its fix.
#
# A pull request opens holding only its failing test, with a title that starts
# "red:", and the CI run of that commit is its red evidence (agent-core v8).
# The fix is pushed to the same branch after the title loses "red:". ci.yml
# cancels a pull request's run when a newer commit supersedes it, so without
# an exception the fix push would cancel the red run, often before it has
# failed. So while the title starts "red:", each push is a group of its own
# commit and is never cancelled: keyed by the commit and not only by the
# branch, because GitHub keeps one pending run per group even with cancelling
# off, and a second push sharing the group would replace a red run waiting
# for a runner. Every other pull request run still cancels the one it
# supersedes.
#
#   bash scripts/tests/red-runs-uncancelled.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0

block="$(awk '/^concurrency:/{f=1;next} f&&/^[^ ]/{exit} f{sub(/^[ \t]+/,""); print}' \
    "$REPO/.github/workflows/ci.yml")"

expect() {
    case "$block" in
        *"$1"*) ;;
        *) echo "FAIL: $2"; fails=$((fails + 1)) ;;
    esac
}

expect "cancel-in-progress: \${{ github.event_name == 'pull_request' && !startsWith(github.event.pull_request.title, 'red:') }}" \
    "ci.yml cancels only a pull request's superseded run, never a red: pull request's"
expect "github.head_ref || format('{0}-{1}', github.ref_name, github.sha)" \
    "ci.yml keeps one group per pull request branch, and per commit on main"
expect "startsWith(github.event.pull_request.title, 'red:') && format('-red-{0}', github.event.pull_request.head.sha) || ''" \
    "ci.yml gives each push to a red: pull request a group of its own commit"

if [ "$fails" -gt 0 ]; then
    echo "red-runs-uncancelled: $fails check(s) failed"
    exit 1
fi
echo "red-runs-uncancelled: all checks passed"
