#!/usr/bin/env bash
#
# ci-long-steps-are-bounded.sh — a step that can hang has a ceiling.
#
# `.github/workflows/ci.yml` carried no `timeout-minutes` anywhere, so a
# hung step ran to GitHub's default of 360 minutes at 10x macOS billing.
# One run held a macos runner for 67m39s on a docs-only diff and went
# green.
#
# THE BOUND GOES ON THE STEP, NOT THE JOB. The test job also carries
# `Build libraries`, skipped on a vendor-cache hit and unmeasured on a
# miss — a job bound safe for a cold cache is too big to catch the test
# step hanging.
#
# THIS CAPS THE BILL AND DIAGNOSES NOTHING. What that run was doing for
# the extra hour is not established, and a ceiling does not find out.
#
# The rule is stated over the COMMAND rather than over one step's name,
# so a second step running the suite is covered without anyone
# remembering this file exists.
#
# PARSED, NOT GREPPED. `timeout-minutes:` can sit at job level or step
# level and a line scan cannot tell which — and job level is the answer
# this check exists to reject. Ruby's stdlib YAML is the parser; it is
# present on the runner image and on a developer's mac.
#
#   bash scripts/tests/ci-long-steps-are-bounded.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0

ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

command -v ruby >/dev/null 2>&1 || {
    echo "ci-long-steps-are-bounded: ruby is required to parse the workflow" >&2
    exit 1
}

# THE SCOPE IS ci.yml AND THE STEP THAT RUNS THE SUITE, and that is a
# decision rather than laziness. A first pass rated every step whose
# `run` mentioned a long tool and failed eight of them, including
# `Select Xcode` (which runs `xcodebuild -version`) and every step in
# release.yml. Those are unbounded too — measured, not assumed, by that
# same pass — but nobody has timed them, and a guard that demands eight
# numbers nobody has measured is a guard that gets an `# allow` comment
# rather than a fix. release.yml wants its own row.
WORKFLOW="$REPO/.github/workflows/ci.yml"

report="$(ruby -ryaml -e '
  doc = YAML.safe_load(File.read(ARGV[0]), aliases: true) || {}
  (doc["jobs"] || {}).each do |job_name, job|
    (job["steps"] || []).each do |step|
      next unless step["run"].to_s.include?("xcodebuild test")
      label = step["name"] || "(unnamed)"
      puts [job_name, label, step["timeout-minutes"]].join("\t")
    end
  end
' "$WORKFLOW" 2>/dev/null)"

if [ -z "$report" ]; then
    # NOT SILENCE. A workflow this reader failed to parse looks exactly
    # like one with nothing to check, and reporting nothing would be the
    # defect this whole file is about.
    if ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]), aliases: true)' "$WORKFLOW" >/dev/null 2>&1; then
        fail "ci.yml parses but runs no \`xcodebuild test\` at all; this check found nothing to check"
    else
        fail "ci.yml does not parse as YAML, so nothing here was checked"
    fi
else
    while IFS=$'\t' read -r job label bound; do
        [ -n "$job" ] || continue
        if [ -z "$bound" ]; then
            fail "ci.yml: job '$job' step '$label' runs the suite with no timeout-minutes; a hang runs to GitHub's 360-minute default at 10x macOS billing"
        else
            ok "ci.yml: '$label' is bounded at ${bound}m"
        fi
    done <<EOF
$report
EOF
fi

# THE CONTROL. The loop above is silent about a step it cannot see, so a
# reader that found no steps at all would print only 'ok' lines. This
# names the one step the defect was filed against.
bound="$(ruby -ryaml -e '
  doc = YAML.safe_load(File.read(ARGV[0]), aliases: true)
  step = (doc["jobs"]["test"]["steps"] || []).find { |s| s["name"] == "Test" }
  print step ? step["timeout-minutes"].inspect : "no-such-step"
' "$REPO/.github/workflows/ci.yml" 2>/dev/null)"
case "$bound" in
    "no-such-step"|"nil"|"") fail "ci.yml's test job has no bounded step named 'Test': got ${bound:-<empty>}" ;;
    *) ok "ci.yml's 'Test' step is the one that was unbounded, and it reads $bound" ;;
esac

# AND THE BOUND IS NOT ON THE JOB, which is the answer this check
# exists to reject: it would cover `Build libraries` too, whose cold
# cost is unmeasured.
job_level="$(ruby -ryaml -e '
  doc = YAML.safe_load(File.read(ARGV[0]), aliases: true)
  print doc["jobs"]["test"]["timeout-minutes"].inspect
' "$REPO/.github/workflows/ci.yml" 2>/dev/null)"
if [ "$job_level" = "nil" ]; then
    ok "the bound is on the step, not on the job"
else
    fail "ci.yml's test job carries a job-level timeout-minutes ($job_level); it also runs \
Build libraries, whose cold cost is unmeasured, so a job bound cannot be tight enough"
fi

if [ "$fails" -eq 0 ]; then
    echo "ci-long-steps-are-bounded: all checks passed"
else
    echo "ci-long-steps-are-bounded: $fails check(s) failed" >&2
fi
exit $(( fails > 0 ))
