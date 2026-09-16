#!/usr/bin/env bash
#
# ci-long-steps-selector.sh — the step guard finds a suite however the
# command is spelled (diskjockey#147).
#
# `ci-long-steps-are-bounded.sh` selected steps with
# `include?("xcodebuild test")`, so `xcodebuild -scheme X test`, or an
# invocation split by a line continuation, was skipped without a word
# while the correctly-spelled neighbour printed `ok`. A partial miss is
# the realistic one and the guard's canary (no step matched at all) cannot
# see it. The job-level ceiling check also printed `ok … ceiling (m)` for a
# workflow with no `test` job, a pass for a value that does not exist.
#
# Drives the real guard against synthetic workflows via
# CI_WORKFLOW_UNDER_TEST. Every synthetic run fails LATER checks that
# expect the repository's own ci.yml, so the exit status says nothing
# here: the assertions are on the lines each check prints.
#
#   bash scripts/tests/ci-long-steps-selector.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO/scripts/tests/ci-long-steps-are-bounded.sh"
fails=0
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

head_ok='on:
  pull_request:
jobs:
  test:
    runs-on: macos-latest
    timeout-minutes: 40
    steps:
      - name: Test
        timeout-minutes: 25
        run: xcodebuild test -scheme DiskJockey
'
guard() { printf '%s' "$1" > "$sandbox/ci.yml"; CI_WORKFLOW_UNDER_TEST="$sandbox/ci.yml" bash "$GUARD" 2>&1; }
has()   { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

echo "ci-long-steps-selector: spellings of a suite run"

# CONTROL: the harness reaches the check. The bounded adjacent spelling is ok.
out=$(guard "$head_ok")
has "$out" "ok    ci.yml: 'Test' is bounded at 25m" && ok "control: the adjacent bounded step is ok" \
    || fail "control: the adjacent bounded step was not reported ok"

# THE DEFECT, three spellings of one unbounded suite beside the bounded one.
for spelling in \
    'xcodebuild -scheme DiskJockey test' \
    $'|\n          xcodebuild \\\n            -scheme DiskJockey \\\n            test' \
    'xcodebuild -project DiskJockey.xcodeproj -scheme DiskJockey -destination platform=macOS test | xcbeautify'
do
    out=$(guard "${head_ok}      - name: Second suite
        run: ${spelling}
")
    has "$out" "FAIL  ci.yml: job 'test' step 'Second suite' runs the suite with no timeout-minutes" \
        && ok "an unbounded step is FAILed when spelled: $(printf '%s' "$spelling" | tr '\n' ' ' | tr -s ' ')" \
        || fail "an unbounded step went unreported when spelled: $(printf '%s' "$spelling" | tr '\n' ' ' | tr -s ' ')"
done

# ACCEPTANCE: a reordered spelling that IS bounded passes, so the fix is
# not a widening that refuses valid workflows.
out=$(guard "${head_ok}      - name: Second suite
        timeout-minutes: 20
        run: xcodebuild -scheme DiskJockey test
")
has "$out" "ok    ci.yml: 'Second suite' is bounded at 20m" && ok "a bounded reordered step is ok" \
    || fail "a bounded reordered step was not reported ok"

# NOT EVERY xcodebuild IS A SUITE: `-version` and `build` must not be
# demanded a bound, or the guard fails steps nobody has timed (see its scope note).
out=$(guard "${head_ok}      - name: Select Xcode
        run: xcodebuild -version
      - name: Build
        run: xcodebuild build -scheme DiskJockey -testPlan Nightly
")
if has "$out" "'Select Xcode'" || has "$out" "'Build'"; then
    fail "a non-test xcodebuild step was selected: $(printf '%s\n' "$out" | grep -E "Select Xcode|'Build'" | head -2 | tr '\n' ' ')"
else
    ok "xcodebuild -version and xcodebuild build are not selected"
fi

# DEFECT 2: no `test` job means no job-level ceiling, which is not an ok.
out=$(guard 'on:
  pull_request:
jobs:
  build:
    runs-on: macos-latest
    steps:
      - run: echo hi
')
if has "$out" "ceiling (m)" || has "$out" "ok    the test job has a ceiling"; then
    fail "a workflow with no test job still prints a ceiling ok: $(printf '%s' "$out" | grep ceiling)"
else
    ok "a workflow with no test job does not print a ceiling ok"
fi

echo
if [ "$fails" = 0 ]; then
    echo "ci-long-steps-selector: all checks passed"
else
    echo "ci-long-steps-selector: $fails check(s) failed" >&2
fi
exit "$fails"
