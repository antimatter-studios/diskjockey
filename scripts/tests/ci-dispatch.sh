#!/usr/bin/env bash
# ci.yml can be started by hand on any branch, and a run started that way is
# the full pipeline. A pull request's test-only commit is pushed to its own
# red/<branch> ref and CI is dispatched there with
# `gh workflow run ci.yml --ref red/<branch>`, so the run records the new tests
# failing without the fix (#405). Without `workflow_dispatch` that dispatch is
# refused; with it but with the `changes` job answering `false`, or a job gated
# on the event, the run is green for having tested nothing -- which reads
# exactly like the red it was meant to record never happening.
#
#   bash scripts/tests/ci-dispatch.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CI="$REPO/.github/workflows/ci.yml"

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }

[ -f "$CI" ] || { echo "FAIL  .github/workflows/ci.yml is missing" >&2; exit 1; }

# The triggers: the keys indented one level under the top-level `on:`.
triggers="$(awk '
    /^on:/ { inside = 1; next }
    inside && /^[^ #]/ { exit }
    inside && /^  [a-z_]+:/ { sub(/^  /, ""); sub(/:.*/, ""); print }
' "$CI")"

for want in pull_request merge_group workflow_dispatch; do
    if grep -qx "$want" <<<"$triggers"; then
        ok "ci.yml runs on $want"
    else
        bad "ci.yml does not run on $want (its triggers: $(tr '\n' ' ' <<<"$triggers"))"
    fi
done

# The `changes` job's classifier, run as a dispatch would run it. A dispatch
# carries no pull request, merge group or push range, so the classifier has
# nothing to diff and must answer `true`: the full pipeline, so the Xcode build
# and the library tests run rather than being skipped as a documentation-only
# change. This executes the script in ci.yml rather than reading it, so it
# holds whatever the script becomes.
classify="$(awk '
    /^      - name: Classify the change/ { inside = 1; next }
    inside && /^        run: \|/ { body = 1; next }
    body && /^          / { sub(/^          /, ""); print; next }
    body && /^$/ { print; next }
    body { exit }
' "$CI")"

if ! grep -q 'GITHUB_OUTPUT' <<<"$classify"; then
    bad "the changes job's classifier was not found in ci.yml (step \"Classify the change\")"
else
    sandbox="$(mktemp -d)"
    trap 'rm -rf "$sandbox"' EXIT
    out="$sandbox/github-output"
    : > "$out"
    (
        cd "$sandbox" &&
            EVENT=workflow_dispatch REF=refs/heads/red/some-branch \
            PR_BASE='' PR_HEAD='' MQ_BASE='' MQ_HEAD='' PUSH_BEFORE='' PUSH_AFTER='' \
            GITHUB_OUTPUT="$out" bash -c "$classify"
    ) > "$sandbox/log" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ] && grep -qx 'code=true' "$out"; then
        ok "a dispatch is classified as needing the full pipeline"
    else
        bad "a dispatch is not classified code=true (rc $rc, output: $(cat "$out"), log: $(cat "$sandbox/log"))"
    fi
fi

# A job or step gated on the event, or on the event's payload, can drop a
# dispatch from the pipeline while every check above still passes: a dispatch
# has no pull request in its payload. None is gated that way today; one that
# needs to be must extend this guard to prove a dispatch still runs it.
gated="$(grep -nE '^ *if:.*github\.event(_name|\.)' "$CI" || true)"
if [ -z "$gated" ]; then
    ok "no job or step is gated on the event that started the run"
else
    bad "ci.yml gates on the event, which can skip a dispatch: $gated"
fi

[ "$fails" -eq 0 ] || exit 1
echo "ci-dispatch: all checks passed"
