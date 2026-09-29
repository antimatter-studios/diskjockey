#!/usr/bin/env bash
#
# quiet-run.sh — run one test tier quietly, keep all of it, and hold it to a
# measured budget (#211).
#
# THIS IS DISKJOCKEY'S OWN, not a copy of the family's output-budget wrapper.
# This repository has no tier.sh and does not borrow one (AGENTS.md, "Where the
# shared block does not map cleanly"): the family's wrapper lives in a crate
# this repository does not depend on. It meets the same contract, because that
# is what keeps the family's CI logs comparable:
#
#   pass          one verdict line naming the log; exit 0
#   failure       the verdict, the command's own exit status and the log path,
#                 and no tail; the wrapper exits with the command's status,
#                 never tee's or a renderer's
#   over budget   a pass whose log outgrew its line or byte budget exits 65,
#                 so a suite that got louder is told apart from one that broke
#   --verbose     (or OUTPUT_BUDGET_VERBOSE=1) streams the run live, through
#                 --render's command if one is named, and does NOT lift the
#                 budget: the budget caps the log, not what was shown
#
# The log is the command's raw stdout and stderr, never the rendered view:
# when a build fails it is a link error or a signing refusal, not a test, and
# only the raw stream has it. It lands in tmp/logs/<tier>.log (QUIET_LOG_DIR
# overrides the directory), which .gitignore and .github-guard's
# paths.private both keep out of a commit, and CI uploads it on every run.
#
#   scripts/quiet-run.sh [--verbose] [--render CMD] <tier> <max-lines> <max-bytes> -- <command> [args...]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo "usage: quiet-run.sh [--verbose] [--render CMD] <tier> <max-lines> <max-bytes> -- <command> [args...]" >&2; exit 2; }

verbose=0
case "${OUTPUT_BUDGET_VERBOSE:-}" in ""|0|false|no) ;; *) verbose=1 ;; esac
render=""
while [ $# -gt 0 ]; do
    case "$1" in
        --verbose) verbose=1; shift ;;
        --render)  [ $# -ge 2 ] || usage; render="$2"; shift 2 ;;
        *) break ;;
    esac
done
[ $# -ge 5 ] && [ "$4" = "--" ] || usage
tier="$1" max_lines="$2" max_bytes="$3"
shift 4
[[ "$max_lines" =~ ^[0-9]+$ && "$max_bytes" =~ ^[0-9]+$ ]] || usage

dir="${QUIET_LOG_DIR:-$ROOT/tmp/logs}"
mkdir -p "$dir" || exit 2
log="$dir/$tier.log"
shown="${log#"$ROOT"/}"

if [ "$verbose" = 1 ]; then
    if [ -n "$render" ]; then
        "$@" 2>&1 | tee "$log" | bash -c "$render"
    else
        "$@" 2>&1 | tee "$log"
    fi
    rc=${PIPESTATUS[0]}
else
    "$@" > "$log" 2>&1
    rc=$?
fi

lines=$(wc -l < "$log" | tr -d ' ')
bytes=$(wc -c < "$log" | tr -d ' ')

if [ "$rc" != 0 ]; then
    echo "$tier: FAILED (exit $rc, $lines lines) — $shown"
    exit "$rc"
fi
if [ "$lines" -gt "$max_lines" ] || [ "$bytes" -gt "$max_bytes" ]; then
    echo "$tier: OVER BUDGET — passed, but printed $lines lines / $bytes bytes against $max_lines lines / $max_bytes bytes; raise the budget with a measurement, do not silence the run — $shown"
    exit 65
fi
echo "$tier: ok ($lines lines, $bytes bytes; budget $max_lines / $max_bytes) — $shown"
