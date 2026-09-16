#!/usr/bin/env bash
#
# am-slot-waiter.sh — what a waiting caller is told (diskjockey#149).
#
# The one line every waiter reads printed the configured LIMIT as the
# occupancy, "($LIMIT in use) — queued, not stuck", without counting a
# holder. Measured: `--status` said the pool was idle while the same tool
# told a waiter "1 in use"; with one live holder it said "2 in use". And a
# caller the reservation made permanently ineligible (LIMIT=1, not on the
# list) was told it was queued and waited the full AM_SLOT_WAIT.
#
# The pool is a scratch AM_SLOT_DIR; the live one is never touched.
#
#   bash scripts/tests/am-slot-waiter.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SLOT="$REPO/scripts/am-slot"
fails=0

sandbox="$(mktemp -d)"
holders=()
cleanup() {
    for p in "${holders[@]}"; do kill "$p" 2>/dev/null; done
    rm -rf "$sandbox"
}
trap cleanup EXIT
export AM_SLOT_DIR="$sandbox/pools"

ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# A live process to name as a holder. Its pid answers kill -0 for as long
# as the test needs it to.
live_pid() { sleep 300 & holders+=("$!"); LIVE=$!; }

fresh() { rm -rf "$AM_SLOT_DIR"; mkdir -p "$AM_SLOT_DIR/p"; }
hold()  { live_pid; printf '%s|%s\n' "$2" "$LIVE" > "$AM_SLOT_DIR/p/$1.slot"; }

echo "am-slot-waiter: the waiter's message"

# 1. CASE B, the live shape: one live holder, a reservation for someone
#    else, slot 1 free inside the grace window, caller not reserved.
fresh; echo someone-else > "$AM_SLOT_DIR/p.reserved"; hold 2 builder
msg=$(AM_SLOT_LIMIT=2 AM_SLOT_WAIT=0 AM_SLOT_NAME=audit "$SLOT" p true 2>&1)
case "$msg" in
    *"(1 of 2 held"*) ok "one live holder is reported as 1 of 2 held" ;;
    *) fail "one live holder: got: $msg" ;;
esac

# 2. CONTROL: two live holders, no reservation. The count must move with
#    the pool, or check 1 could pass on a constant that happens to be 1.
fresh; hold 1 a; hold 2 b
msg=$(AM_SLOT_LIMIT=2 AM_SLOT_WAIT=0 AM_SLOT_NAME=audit "$SLOT" p true 2>&1)
case "$msg" in
    *"(2 of 2 held"*) ok "two live holders are reported as 2 of 2 held" ;;
    *) fail "two live holders: got: $msg" ;;
esac

# 3. A DEAD HOLDER IS NOT A HOLDER. A stale slot file whose pid is gone is
#    reclaimable, and counting it is the same constant in disguise.
fresh; hold 2 alive; dead=99999; while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
printf 'gone|%s\n' "$dead" > "$AM_SLOT_DIR/p/1.slot"
echo someone-else > "$AM_SLOT_DIR/p.reserved"
msg=$(AM_SLOT_LIMIT=2 AM_SLOT_WAIT=0 AM_SLOT_NAME=audit "$SLOT" p true 2>&1)
case "$msg" in
    *"(1 of 2 held"*) ok "a stale slot file is not counted as a holder" ;;
    *) fail "stale slot: got: $msg" ;;
esac

# 4. CASE A: a caller the reservation excludes for good is refused at once,
#    not queued. AM_SLOT_WAIT is long enough that a queued caller would
#    still be waiting when the timer below gives up.
fresh; echo someone-else > "$AM_SLOT_DIR/p.reserved"
start=$(date +%s)
msg=$(AM_SLOT_LIMIT=1 AM_SLOT_WAIT=30 AM_SLOT_NAME=audit "$SLOT" p true 2>&1); rc=$?
took=$(( $(date +%s) - start ))
if [ "$rc" -ne 0 ] && [ "$took" -lt 10 ]; then
    ok "a never-eligible caller is refused in ${took}s with rc=$rc"
else
    fail "a never-eligible caller: rc=$rc after ${took}s: $msg"
fi
case "$msg" in
    *"queued, not stuck"*) fail "a never-eligible caller is still told it is queued: $msg" ;;
    *"reserved"*) ok "and the refusal names the reservation" ;;
    *) fail "the refusal does not say why: $msg" ;;
esac

# 5. ACCEPTANCE: an idle, unreserved pool runs the command and passes its
#    status through, so the new paths did not break the plain one.
fresh
AM_SLOT_LIMIT=2 AM_SLOT_WAIT=0 AM_SLOT_NAME=audit "$SLOT" p sh -c 'exit 7' 2>/dev/null; rc=$?
[ "$rc" = 7 ] && ok "an idle pool runs the command and returns its status" \
             || fail "an idle pool returned $rc, expected 7"

echo
if [ "$fails" = 0 ]; then
    echo "am-slot-waiter: all checks passed"
else
    echo "am-slot-waiter: $fails check(s) failed" >&2
fi
exit "$fails"
