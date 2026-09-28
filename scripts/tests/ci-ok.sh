#!/usr/bin/env bash
# The aggregate gate rejects every non-success result and covers all CI jobs.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo/scripts/check-ci-results.sh"
workflow="$repo/.github/workflows/ci.yml"
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

check_result() { # label, expected exit, joined results
    local label="$1" expected="$2" results="$3" output rc
    output="$(bash "$checker" "$results" 2>&1)"; rc=$?
    if [ "$rc" -eq "$expected" ]; then ok "$label"; else fail "$label: exit $rc, wanted $expected: $output"; fi
}

check_result 'three successes pass' 0 'success success success'
check_result 'a failed leg fails' 1 'success failure success'
check_result 'a cancelled leg fails' 1 'cancelled success success'
check_result 'a skipped leg fails' 1 'success success skipped'
check_result 'an empty result fails' 1 ''
check_result 'a missing leg fails' 1 'success success'
check_result 'an extra leg needs review' 1 'success success success success'

# Parse job structure rather than accepting an `always()` in a comment or
# a needs list attached to a different job.
if ruby -ryaml -e '
    doc = YAML.safe_load(File.read(ARGV[0]), aliases: true)
    job = doc.fetch("jobs").fetch("ci-ok")
    abort "wrong dependencies" unless job.fetch("needs").sort == %w[library-tests scripts test].sort
    abort "job must run after failed/skipped needs" unless job.fetch("if") == "always()"
    abort "wrong job name" unless job.fetch("name") == "ci-ok"
    step = job.fetch("steps").find { |candidate| candidate.fetch("run", "").include?("check-ci-results.sh") }
    abort "missing gate step" unless step
    abort "missing joined results" unless step.fetch("env").fetch("NEEDED_RESULTS").include?("join(needs.*.result")
' "$workflow" 2>/dev/null; then
    ok 'ci-ok always runs after all three gating jobs'
else
    fail 'ci-ok workflow wiring is missing or incomplete'
fi

if [ "$(git config -f "$repo/.github-guard" --get-all checks.advisory)" = ci-ok ]; then
    ok 'ci-ok is advisory until it has succeeded on main'
else
    fail 'ci-ok must start advisory before main has produced it'
fi

echo
if [ "$fails" -eq 0 ]; then
    echo 'ci-ok: all checks passed'
else
    echo "ci-ok: $fails check(s) failed" >&2
fi
exit "$((fails > 0))"
