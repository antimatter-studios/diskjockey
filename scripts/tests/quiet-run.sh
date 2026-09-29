#!/usr/bin/env bash
#
# quiet-run.sh (test) — the wrapper every test tier runs through (#211).
#
# The contract, each half proved below against a stand-in command:
#
#   pass          one verdict line naming the log; exit 0
#   failure       verdict, the command's own exit status and the log path,
#                 no tail; the command's status is the wrapper's status
#   over budget   a pass whose LOG outgrew its line or byte budget exits 65,
#                 which no suite uses, so it cannot be mistaken for a failure
#   --verbose     streams live (through the renderer, if one is named) and is
#                 still held to the budget
#   the log       holds stdout and stderr both, raw, whatever was shown
#
# QUIET_LOG_DIR points the log at a scratch directory so this test never
# writes into the checkout's tmp/.
#
#   bash scripts/tests/quiet-run.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAP="$REPO/scripts/quiet-run.sh"
fails=0
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
export QUIET_LOG_DIR="$sandbox/logs"
unset OUTPUT_BUDGET_VERBOSE

ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# run <args...>: OUT is what the wrapper printed, RC its status.
run() { OUT="$(bash "$WRAP" "$@" 2>&1)"; RC=$?; }
lines_of() { printf '%s\n' "$1" | grep -c .; }

# A stand-in suite: N lines to stdout, one to stderr, then exit with $2.
suite() { printf 'for i in $(seq 1 %s); do echo "case $i passed"; done; echo "a warning" >&2; exit %s\n' "$1" "$2" > "$sandbox/suite.sh"; }

echo "quiet-run: a quiet pass, a loud failure's status, and a budget that bites"

suite 10 0
run demo 100 10000 -- bash "$sandbox/suite.sh"
[ "$RC" = 0 ] && ok "a passing command exits 0" || fail "a passing command exited $RC: $OUT"
[ "$(lines_of "$OUT")" = 1 ] && ok "and prints exactly one line" || fail "a pass printed $(lines_of "$OUT") lines: $OUT"
case "$OUT" in
    *"demo: ok"*"$QUIET_LOG_DIR/demo.log"*) ok "which is the verdict and names the log" ;;
    *) fail "the pass verdict does not name its log: $OUT" ;;
esac
if grep -qx 'case 10 passed' "$QUIET_LOG_DIR/demo.log" && grep -qx 'a warning' "$QUIET_LOG_DIR/demo.log"; then
    ok "the log holds stdout and stderr both"
else
    fail "the log is missing output: $(cat "$QUIET_LOG_DIR/demo.log" 2>&1 | head -3)"
fi
[ "$(grep -c . "$QUIET_LOG_DIR/demo.log")" = 11 ] && ok "and nothing else" || fail "the log has $(grep -c . "$QUIET_LOG_DIR/demo.log") lines, wanted 11"

suite 5 3
run demo 100 10000 -- bash "$sandbox/suite.sh"
[ "$RC" = 3 ] && ok "a failing command's own status (3) passes straight through" || fail "a command exiting 3 made the wrapper exit $RC"
[ "$(lines_of "$OUT")" = 1 ] && ok "and a failure prints no tail by default" || fail "a failure printed $(lines_of "$OUT") lines: $OUT"
case "$OUT" in
    *"FAILED"*"exit 3"*"$QUIET_LOG_DIR/demo.log"*) ok "the failure verdict names the status and the log" ;;
    *) fail "the failure verdict lacks the status or the log: $OUT" ;;
esac

suite 5 1
run demo 1 10000 -- bash "$sandbox/suite.sh"
[ "$RC" = 1 ] && ok "a failure over budget is still the command's failure, not 65" || fail "a failing, over-budget run exited $RC"

suite 20 0
run demo 10 100000 -- bash "$sandbox/suite.sh"
[ "$RC" = 65 ] && ok "a pass over its line budget exits 65" || fail "21 lines against a budget of 10 exited $RC: $OUT"
case "$OUT" in
    *"OVER BUDGET"*"21 lines"*) ok "and says what it measured" ;;
    *) fail "the over-budget verdict does not say what it measured: $OUT" ;;
esac

run demo 1000 50 -- bash "$sandbox/suite.sh"
[ "$RC" = 65 ] && ok "a pass over its byte budget exits 65" || fail "a pass over 50 bytes exited $RC: $OUT"

run demo 21 100000 -- bash "$sandbox/suite.sh"
[ "$RC" = 0 ] && ok "a run exactly at its budget passes" || fail "21 lines against a budget of 21 exited $RC"

run --verbose demo 1000 100000 -- bash "$sandbox/suite.sh"
[ "$RC" = 0 ] && [ "$(lines_of "$OUT")" -ge 21 ] && ok "--verbose streams the whole run" \
    || fail "--verbose printed $(lines_of "$OUT") lines, exit $RC"

run --verbose demo 10 100000 -- bash "$sandbox/suite.sh"
[ "$RC" = 65 ] && ok "and does not lift the budget" || fail "--verbose over budget exited $RC"

OUT="$(OUTPUT_BUDGET_VERBOSE=1 bash "$WRAP" demo 1000 100000 -- bash "$sandbox/suite.sh" 2>&1)"; RC=$?
[ "$RC" = 0 ] && [ "$(lines_of "$OUT")" -ge 21 ] && ok "OUTPUT_BUDGET_VERBOSE=1 does the same" \
    || fail "OUTPUT_BUDGET_VERBOSE=1 printed $(lines_of "$OUT") lines, exit $RC"

run --verbose --render 'sed s/passed/RENDERED/' demo 1000 100000 -- bash "$sandbox/suite.sh"
case "$OUT" in
    *"case 3 RENDERED"*) ok "--verbose shows the stream through the named renderer" ;;
    *) fail "the renderer was not applied: $(printf '%s' "$OUT" | head -2)" ;;
esac
grep -qx 'case 3 passed' "$QUIET_LOG_DIR/demo.log" && ok "while the log keeps the raw stream" \
    || fail "the log holds the rendered stream rather than the raw one"

suite 5 4
run --verbose --render cat demo 1000 100000 -- bash "$sandbox/suite.sh"
[ "$RC" = 4 ] && ok "a verbose failure still reports the command's status, not the renderer's" \
    || fail "a verbose run of a command exiting 4 exited $RC"

run --render cat demo 1000 100000 -- bash "$sandbox/suite.sh"
[ "$(lines_of "$OUT")" = 1 ] && ok "a renderer does nothing without --verbose" || fail "a quiet run with a renderer printed $(lines_of "$OUT") lines"

run demo 1000 -- true
[ "$RC" != 0 ] && [ "$RC" != 65 ] && ok "a missing budget is a usage error" || fail "a call with one budget exited $RC"

run demo ten 1000 -- true
[ "$RC" != 0 ] && [ "$RC" != 65 ] && ok "a budget that is not a number is a usage error" || fail "a non-numeric budget exited $RC"

run demo 10 1000 -- "$sandbox/does-not-exist"
[ "$RC" != 0 ] && [ "$RC" != 65 ] && ok "a command that cannot run is a failure" || fail "a missing command exited $RC"

echo
if [ "$fails" -eq 0 ]; then
    echo 'quiet-run: all checks passed'
else
    echo "quiet-run: $fails check(s) failed" >&2
fi
exit "$((fails > 0))"
