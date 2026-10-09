#!/usr/bin/env bash
# The aggregate gate rejects every non-success result and covers all CI jobs.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo/scripts/check-ci-results.sh"
workflow="$repo/.github/workflows/ci.yml"
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

check_result() { # label, expected exit, joined results, code output
    local label="$1" expected="$2" results="$3" code="${4:-true}" output rc
    output="$(bash "$checker" "$results" "$code" 2>&1)"; rc=$?
    if [ "$rc" -eq "$expected" ]; then ok "$label"; else fail "$label: exit $rc, wanted $expected: $output"; fi
}

check_result 'four successes pass' 0 'success success success success'
check_result 'a failed leg fails' 1 'success success failure success'
check_result 'a cancelled leg fails' 1 'success cancelled success success'
check_result 'a skipped leg fails' 1 'success success success skipped'
check_result 'an empty result fails' 1 ''
check_result 'a missing leg fails' 1 'success success success'
check_result 'an extra leg needs review' 1 'success success success success success'
check_result 'documentation alone may skip the macOS legs' 0 'success success skipped skipped' false
check_result 'a skip with code changed fails' 1 'success success skipped skipped' true
check_result 'a skip with no code output fails' 1 'success success skipped skipped' ''
check_result 'documentation alone still fails a failed leg' 1 'success failure skipped skipped' false

# Parse job structure rather than accepting an `always()` in a comment or
# a needs list attached to a different job.
if ruby -ryaml -e '
    doc = YAML.safe_load(File.read(ARGV[0]), aliases: true)
    job = doc.fetch("jobs").fetch("ci-ok")
    abort "wrong dependencies" unless job.fetch("needs").sort == %w[changes library-tests scripts test].sort
    abort "job must run after failed/skipped needs" unless job.fetch("if") == "always()"
    abort "wrong job name" unless job.fetch("name") == "ci-ok"
    step = job.fetch("steps").find { |candidate| candidate.fetch("run", "").include?("check-ci-results.sh") }
    abort "missing gate step" unless step
    abort "missing joined results" unless step.fetch("env").fetch("NEEDED_RESULTS").include?("join(needs.*.result")
    abort "missing code output" unless step.fetch("env").fetch("CODE") == "${{ needs.changes.outputs.code }}"
' "$workflow" 2>/dev/null; then
    ok 'ci-ok always runs after the changes job and all three gating jobs'
else
    fail 'ci-ok workflow wiring is missing or incomplete'
fi

# ci-ok succeeded on main before it was declared (#205), so it is required
# now. The three legs stay required beside it: an aggregate is a claim about
# other jobs, and each leg must still report success under its own name.
required="$(git config -f "$repo/.github-guard" --get-all checks.required | LC_ALL=C sort | tr '\n' '|')"
if [ "$required" = 'Build & Test|Library tests|Shell scripts|ci-ok|' ]; then
    ok 'ci-ok is required beside the three legs'
else
    fail "required checks are not the three legs plus ci-ok: $required"
fi

if git config -f "$repo/.github-guard" --get-all checks.advisory | grep -qx ci-ok; then
    fail 'ci-ok is still declared advisory as well as required'
else
    ok 'ci-ok is no longer advisory'
fi

echo
if [ "$fails" -eq 0 ]; then
    echo 'ci-ok: all checks passed'
else
    echo "ci-ok: $fails check(s) failed" >&2
fi
exit "$((fails > 0))"
