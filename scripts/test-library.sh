#!/usr/bin/env bash
#
# test-library.sh — the library tier: DiskJockeyLibraryTests through
# `swift test`, host-free, the way the `Library tests` CI job runs it and
# `chore test:library` does (#211).
#
# `swift test`, not xcodebuild: an .xctest bundle needs a process to host it,
# and xcodebuild launches its own runner through RunningBoard, which refused
# even the host-free bundle with error 5 on 2026-09-10. `swift test` links the
# tests into a binary and runs it: nothing to launch, nothing to sign. See
# Package.swift's header and diskjockey#139.
#
# Quiet by default: the raw run goes to tmp/logs/library.log through
# scripts/quiet-run.sh, and the terminal gets the verdict and the count.
# `--verbose` (or OUTPUT_BUDGET_VERBOSE=1) streams it, held to the same budget.
#
# A FLOOR, BECAUSE THE FAILURE MODE HERE IS AN ABSENCE TOO. A run that builds
# and then executes nothing exits 0 having reported no failures. Only a count
# sees it. Both frameworks are in this target and each prints its own total:
# XCTest's "Executed N tests" (once per suite plus once for the bundle, so
# take the largest) and swift-testing's "Test run with N tests".
# Measured 2026-09-10: 51 + 39 = 90, then 51 + 65 = 116, 51 + 78 = 129,
# 51 + 109 = 160, 51 + 132 = 183, 51 + 153 = 204, 51 + 178 = 229, then
# 51 + 191 = 242 with the shared readlink contract (2026-09-28), then
# 51 + 200 = 251 with the diskutil pass taken off the main actor, then
# 51 + 207 = 258 with dirent names read by their declared length, then
# 51 + 222 = 273 with names kept as bytes, then 51 + 225 = 276 with NTFS names
# read by their declared length, then 51 + 229 = 280 with the mount-table pass
# taken off the main actor, then 51 + 259 = 310 with #251's name-bytes tests
# and a mount's credentials kept out of the registry's UserDefaults suite (all
# 2026-09-29), then 51 + 288 = 339 with the XFS volume tested as itself,
# then 51 + 317 = 368 with the EROFS volume, then 51 + 342 = 393 with the
# agent's authority checks under DiskJockeyAgentCoreTests,
# then 51 + 371 = 422 with the Btrfs volume tested as itself,
# then 51 + 401 = 452 with the SquashFS volume tested as itself (all 2026-09-30).
# The floor moves up with the suite; it never moves down.
#
#   scripts/test-library.sh [--verbose]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

rc=0
scripts/quiet-run.sh "$@" library 2150 168000 -- swift test || rc=$?
log="${QUIET_LOG_DIR:-$ROOT/tmp/logs}/library.log"

xct=$(grep -aoE 'Executed [0-9]+ tests' "$log" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)
swt=$(grep -aoE 'Test run with [0-9]+ tests' "$log" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)
total=$(( ${xct:-0} + ${swt:-0} ))
echo "library cases executed: $total = ${xct:-0} XCTest + ${swt:-0} swift-testing (floor 452)"
if [ "$total" -lt 452 ]; then
    echo "::error::only $total library cases executed, floor is 452 — 452 ran on 2026-09-30, and a run that executes less than that has stopped early rather than passed (diskjockey#139)"
    exit 1
fi
exit "$rc"
