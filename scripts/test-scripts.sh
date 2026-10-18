#!/usr/bin/env bash
#
# test-scripts.sh — the scripts tier: every scripts/tests/*.sh guard, the way
# the `Shell scripts` CI job runs them and `chore check:scripts` does (#211).
#
# Quiet by default: the whole transcript goes to tmp/logs/scripts.log through
# scripts/quiet-run.sh, and a pass prints the wrapper's verdict and the count.
# A failure prints the verdict, then each failing script and its own FAIL lines.
# `--verbose` (or OUTPUT_BUDGET_VERBOSE=1) streams the transcript instead, and
# is held to the same budget.
#
# THE SUMMARY LINE IS PART OF THE CONTRACT, because exit 0 is not evidence a
# script finished. An `exit 0` injected anywhere in one of these files gives
# status 0 having run a prefix of its checks, with no failure named. Measured
# on am-ledger-lock.sh: 13 of 22 checks, exit 0, accepted. Every script here
# ends by printing `<name>: all checks passed`, so requiring it as the LAST
# line turns a truncated run into a failure.
#
# A FLOOR, NOT A ZERO CHECK. A glob that matches nothing passes having run
# nothing, but so does a glob that matches four files out of twenty: what
# actually happens is a rename, a moved directory, or a file that stops ending
# in `.sh`. So count, and refuse a number that means the run stopped short.
# Measured 2026-09-17 on run 35238130306 (`main`): 20 ran, floor 18. Measured
# 2026-09-29 with chore-pin.sh (#79): 26 ran, floor 24. Measured again when
# quiet-run.sh and test-tiers.sh joined (#211): 28 ran, floor 26, and 29 when
# dirent-names-by-length.sh joined (#244), floor 27. 31 ran when
# dev-registry.sh joined (#167, 2026-09-30), floor 29 — the same
# room to retire a couple deliberately, and none for a glob that quietly
# stopped matching. The XFS callback wiring guard brings the measured suite
# to 43 files on 2026-10-07 (#320), floor 43.
# The XFS v5 release-runner contract brings it to 44 files (#325), floor 44.
# The branch reaper's guard brings it to 45 files on 2026-10-11, floor 45.
# main held 46 files on 2026-10-14, and the XFS mutation oracle's guard
# (#355) brings it to 47, floor 47.
# main's run 38992160207 (2026-10-17) ran 47 in 773 lines / 40,698 bytes, and
# the CI dispatch guard (#405) brings it to 48 files, floor 48.
# The CLI capability executor guard (#401), together with the CI dispatch
# guard (#405) and DriverKit mount-contract guard (#392), brings the measured
# glob to 50 files on 2026-10-18, floor 50.
# The DriverKit mount-contract guard (#392) brings the tracked inventory to
# 50 files on 2026-10-18, floor 50; execution is verified by CI.
# The CLI exit-status contract guard (#411) brings it to 51 files, floor 51.
# The DriverKit service target guard (#393) raises the inventory to 52 files.
# The DriverKit reader-boundary guard (#418) raises it to 53 files.
# The agent-side VHDX ABI guard (#424) raises it to 54 files.
# The read wire contract guard (#428) raises it to 55 files.
# The pending-read lifecycle guard (#429) raises it to 56 files.
# The agent read server guard (#433) raises it to 57 files.
# The user-client dispatch guard (#434) raises it to 58 files.
# The agent serve-loop guard (#443) raises it to 59 files.
# The owned attachment lifecycle guard (#447) raises it to 60 files.
# The agent media correlation guard (#451) raises it to 61 files.
# The agent bridge authorization guard (#456) raises it to 62 files.
# The dext mount-selector guard (#460) raises it to 63 files.
# The dext block-I/O guard (#461) raises it to 64 files.
# The agent bridge mount-selector guard (#458) raises it to 65 files.
# The trusted XPC connection ownership guard (#453) raises it to 66 files.
# The owned DriverKit XPC route guard (#454) raises it to 67 files.
# The retained image eject route guard (#480) raises it to 68 files.
# It moves up with the suite; it never moves down.
#
# `rc`, not `status`: `status` is READ-ONLY in zsh, so a loop written with it
# works under bash and dies with "read-only variable" anywhere else.
#
#   scripts/test-scripts.sh [--verbose]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
FLOOR=68

# The raw loop, whose whole output is the tier's log. Failure lines carry a
# TIER-FAIL prefix so the quiet verdict below can name them without a tail.
if [ "${1:-}" = "--run-all" ]; then
    shopt -s nullglob
    found=0
    bad=0
    for t in scripts/tests/*.sh; do
        echo "== $t"
        rc=0
        out="$(bash "$t" 2>&1)" || rc=$?
        printf '%s\n' "$out"
        want="$(basename "$t" .sh): all checks passed"
        if [ "$rc" != 0 ]; then
            echo "TIER-FAIL $t exited $rc"
            printf '%s\n' "$out" | grep -E '^FAIL' | head -10 | sed 's/^/TIER-FAIL   /'
            bad=$((bad + 1))
        elif [ "$(printf '%s\n' "$out" | tail -1)" != "$want" ]; then
            echo "TIER-FAIL $t exited 0 but its last line is not '$want', so it did not run to the end: truncated"
            bad=$((bad + 1))
        fi
        found=$((found + 1))
    done
    echo "ran $found script test(s) (floor $FLOOR)"
    if [ "$found" -lt "$FLOOR" ]; then
        echo "TIER-FAIL only $found script tests ran, floor is $FLOOR, so scripts/tests/*.sh has stopped matching the suite rather than passing it"
        exit 1
    fi
    [ "$bad" = 0 ] || exit 1
    exit 0
fi

rc=0
scripts/quiet-run.sh "$@" scripts 1030 53300 -- bash scripts/test-scripts.sh --run-all || rc=$?
log="${QUIET_LOG_DIR:-$ROOT/tmp/logs}/scripts.log"
grep -E '^ran [0-9]+ script test' "$log" 2>/dev/null | tail -1
grep -E '^TIER-FAIL' "$log" 2>/dev/null | sed 's/^TIER-FAIL //' | head -40
exit "$rc"
