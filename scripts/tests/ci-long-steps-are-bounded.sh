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
# THIS CHECK USED TO ASSERT THE OPPOSITE, and the reversal is deliberate.
#
# It read: the bound belongs on the step, not on the job, because the job also
# runs `Build libraries` "whose cold cost is unmeasured, so a job bound cannot
# be tight enough". The first half of that reasoning was right and the
# conclusion did not follow: the alternative to a loose bound was not a step
# bound, it was NO bound. On 2026-09-10 a post-merge run hung in `Set up Go` —
# step 8 of 25, nowhere near the bounded step — and ran for TWO HOURS on the
# only macos-26 runner in the pool, starving the pull requests queued behind
# it, until a person cancelled it by hand.
#
# And the cold cost is no longer unmeasured. Eight successful `Build & Test`
# jobs on 2026-09-10: 19m08s, 16m48s, 16m45s, 16m31s, 7m56s, 2m10s, 2m07s,
# 1m50s. The slowest good job is **19m08s**, so the job ceiling has to clear
# that with room and the floor below keeps a later reader from tightening it
# into a flaky failure.
if [ "$job_level" = "nil" ]; then
    fail "ci.yml's test job has no job-level timeout-minutes: a hang in any step \
other than the bounded one runs to GitHub's 360-minute default, which is what \
happened on 2026-09-10 in Set up Go"
elif [ "$job_level" -lt 30 ] 2>/dev/null; then
    fail "ci.yml's test job ceiling is ${job_level}m, under the 30m floor: the \
slowest good job measured is 19m08s and a tight ceiling turns a slow runner into \
a red build"
else
    ok "the test job has a ceiling (${job_level}m) above the 19m08s slowest good run"
fi

# ---------------------------------------------------------------- job bounds
# The ubuntu job needs one too, for the same reason and at a different scale:
# seven seconds in practice, so five minutes is a hang rather than a slow
# runner — and an unbounded ubuntu job is cheap enough to be forgotten for
# hours, which is how the macOS one was.
for job in scripts; do
    got="$(ruby -ryaml -e 'd=YAML.load_file(ARGV[0]); print(d["jobs"][ARGV[1]]["timeout-minutes"].to_i)' "$WORKFLOW" "$job" 2>/dev/null)"
    if [ "${got:-0}" -gt 0 ] 2>/dev/null; then
        echo "ok    the '$job' job has a ceiling of ${got} minutes"
    else
        echo "FAIL  the '$job' job has no timeout-minutes: a hang outside a bounded step runs for GitHub's default 360" >&2
        fails=$((fails + 1))
    fi
done

if [ "$fails" -eq 0 ]; then
    echo "ci-long-steps-are-bounded: all checks passed"
else
    echo "ci-long-steps-are-bounded: $fails check(s) failed" >&2
fi
exit $(( fails > 0 ))
