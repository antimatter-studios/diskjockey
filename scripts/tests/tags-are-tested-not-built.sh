#!/usr/bin/env bash
#
# tags-are-tested-not-built.sh — a tag runs the tests and produces nothing.
#
# This repository ships a paid app through the App Store, so it publishes no
# release artefacts. That makes a tag pure metadata: it records which commit a
# version was built from, and the evidence it should produce is a public test
# run, not a signed download.
#
# The two halves are one decision and they are in different files, which is
# exactly how a decision comes apart. Before this guard existed the coupling
# ran the other way — `release.yml` triggered on `push: tags`, so marking a
# version and signing a build with the owner's Developer ID were the same
# action, and the repository consequently had NO TAGS AT ALL for three
# releases. Nothing recorded which commit shipped as 1.0.1, 1.1.0 or 1.2.0
# except two local, unpushed refs, one of which pointed at a commit whose own
# project file declared a different version.
#
# So this asserts both halves, and it asserts them against the parsed YAML
# rather than a grep: `on:` is the one key in a workflow that YAML reads as the
# boolean `true`, so a text search for "tags" finds the comments as readily as
# the trigger.
#
#   bash scripts/tests/tags-are-tested-not-built.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CI="$REPO/.github/workflows/ci.yml"
RELEASE="$REPO/.github/workflows/release.yml"
fails=0

check() { # check <what> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "ok — $1"
    else
        echo "FAIL — $1: expected [$2] got [$3]" >&2
        fails=$((fails + 1))
    fi
}

# `on:` parses as the boolean true; ask for both spellings so this does not
# depend on which YAML library reads it.
trigger() { # trigger <file> <ruby expression over the `on` mapping>
    ruby -ryaml -e '
        d = YAML.load_file(ARGV[0])
        on = d.key?(true) ? d[true] : d["on"]
        abort "no on: block" if on.nil?
        print(eval(ARGV[1]))
    ' "$1" "$2" 2>/dev/null
}

command -v ruby >/dev/null 2>&1 || { echo "tags-are-tested-not-built: ruby absent, cannot parse the workflows" >&2; exit 1; }

# ------------------------------------------------------------------ ci.yml
check "ci.yml runs on a v* tag" \
      "true" "$(trigger "$CI" '(on["push"]["tags"] || []).include?("v*")')"
check "ci.yml still runs on main" \
      "true" "$(trigger "$CI" '(on["push"]["branches"] || []).include?("main")')"
check "ci.yml still runs on pull requests" \
      "true" "$(trigger "$CI" 'on.key?("pull_request")')"

# AND EVERY PULL REQUEST IS RUN, WHICHEVER BRANCH IT TARGETS.
#
# `pull_request: branches: [main]` gave a stacked pull request NO run at all,
# and GitHub then reports it as `CLEAN` -- a pull request with no checks has no
# failing checks. Measured 2026-09-10 on two of them: `gh run list --branch
# <head>` returned nothing while `gh pr view` called both mergeable. An absent
# check reads exactly like a passing one to anything scanning for failures.
#
# Asserted as "no `branches` filter" rather than "main is in the filter",
# because the failing shape is a filter that EXCLUDES a base, and any list at
# all excludes every base not on it.
check "ci.yml runs on a pull request against any base branch" \
      "true" "$(trigger "$CI" '!(on["pull_request"] || {}).is_a?(Hash) || !(on["pull_request"] || {}).key?("branches")')"

# A tag run must not cancel a main run. The group keys on ref_name, which for a
# tag is the tag itself; if someone keys it on `github.workflow` alone, pushing
# a tag cancels whatever main is doing.
check "the concurrency group separates a tag from a branch" \
      "true" "$(ruby -ryaml -e 'd=YAML.load_file(ARGV[0]); print d["concurrency"]["group"].include?("ref_name")' "$CI" 2>/dev/null)"

# ------------------------------------------------------------- release.yml
# The load-bearing assertion: no push trigger of any kind. Not "no tags" —
# a branch push would sign a build just as readily.
check "release.yml has no push trigger at all" \
      "false" "$(trigger "$RELEASE" 'on.key?("push")')"
check "release.yml is still manually dispatchable" \
      "true" "$(trigger "$RELEASE" 'on.key?("workflow_dispatch")')"

# And the reason, kept next to the assertion so a reader who disagrees knows
# what they are overruling rather than assuming an oversight.
check "release.yml says why it is manual only" \
      "true" "$(grep -qc 'MANUAL ONLY, DELIBERATELY' "$RELEASE" >/dev/null && echo true || echo false)"

if [ "$fails" -eq 0 ]; then
    echo "tags-are-tested-not-built: all checks passed"
else
    echo "tags-are-tested-not-built: $fails check(s) failed" >&2
fi
exit $(( fails > 0 ))
