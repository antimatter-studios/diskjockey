#!/usr/bin/env bash
#
# am-slot-holders.sh — a slot is removed only by whoever measured it, and it
# is held for as long as the work runs (diskjockey#124, #125).
#
# #124: the stale reclaim read a holder's pid, tested it, then `rm -f`'d
# whatever file sat at that path, so a live holder that took the slot in
# between lost it and two callers ran on one index. `release_slot` had the
# same shape: it removed the path it created, even if another caller had
# since reclaimed and recreated it.
#
# #125: the slot recorded the wrapper shell's pid. Kill the wrapper and the
# slot read free while its build carried on, so the limit admitted another.
#
# Driven through the CLI against a scratch AM_SLOT_DIR. The reclaim crossing
# is made deterministic with a `cut` stub on PATH that replaces the slot file
# right after its dead pid has been read.
#
#   bash scripts/tests/am-slot-holders.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SLOT="$REPO/scripts/am-slot"
fails=0
sandbox="$(mktemp -d)"
pids=()
cleanup() { for p in "${pids[@]}"; do kill -9 "$p" 2>/dev/null; kill -9 -- "-$p" 2>/dev/null; done; rm -rf "$sandbox"; }
trap cleanup EXIT
export AM_SLOT_DIR="$sandbox/pools" AM_SLOT_RESERVE_GRACE=0
P="$AM_SLOT_DIR/p"

ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
fresh() { rm -rf "$AM_SLOT_DIR"; mkdir -p "$P"; }
dead_pid() { local d=99999; while kill -0 "$d" 2>/dev/null; do d=$((d + 1)); done; echo "$d"; }
wait_for() { local i; for i in $(seq 1 50); do eval "$1" && return 0; sleep 0.1; done; return 1; }

echo "am-slot-holders: removals and liveness"

# 1. #124, THE RECLAIM CROSSING. Slot 1 holds a dead pid. Right after the
#    reclaimer reads it, a live holder takes slot 1 (the file is replaced).
#    The reclaimer must not delete the live holder's file.
fresh
sleep 300 & live=$!; disown "$live"; pids+=("$live")
printf 'ghost|%s\n' "$(dead_pid)" > "$P/1.slot"
mkdir -p "$sandbox/bin"
REAL_CUT="$(command -v cut)"
cat > "$sandbox/bin/cut" <<STUB
#!/bin/sh
out=\$("$REAL_CUT" "\$@")
if [ ! -f "$sandbox/crossed" ] && printf '%s' "\$out" | grep -qx "$(sed -n 's/^ghost|//p' "$P/1.slot")"; then
    : > "$sandbox/crossed"
    printf 'liveholder|%s\n' "$live" > "$P/1.slot.new" && mv "$P/1.slot.new" "$P/1.slot"
fi
printf '%s\n' "\$out"
STUB
chmod +x "$sandbox/bin/cut"
PATH="$sandbox/bin:$PATH" AM_SLOT_LIMIT=1 AM_SLOT_WAIT=0 AM_SLOT_NAME=reclaimer "$SLOT" p sh -c 'cat "$1" > "$2"' _ "$P/1.slot" "$sandbox/seen" >/dev/null 2>&1; rc=$?
if [ ! -f "$sandbox/crossed" ]; then
    fail "harness: the crossing never happened, so this check measured nothing"
elif grep -q '^liveholder|' "$P/1.slot" 2>/dev/null && [ "$rc" != 0 ]; then
    ok "a slot re-taken between the reclaimer's read and its removal survives, and the reclaimer waits"
else
    fail "the reclaimer removed a live holder's slot (rc=$rc, slot now: $(cat "$P/1.slot" 2>/dev/null || echo gone), it ran holding: $(cat "$sandbox/seen" 2>/dev/null))"
fi
rm -f "$sandbox/bin/cut" "$sandbox/crossed"

# 2. #124, RELEASE. While a holder runs, its slot is reclaimed and re-created
#    by someone else. When the first holder exits it must not delete the
#    second holder's file.
fresh
sleep 300 & other=$!; disown "$other"; pids+=("$other")
AM_SLOT_LIMIT=1 AM_SLOT_NAME=first "$SLOT" p sleep 1.5 >/dev/null 2>&1 & first=$!; pids+=("$first")
# Wait for the record to carry the command's process group: a live holder
# is never reclaimed, so the replacement this check models happens after
# the holder is fully started, not inside its own startup.
wait_for '[ "$(cut -d"|" -f4 "$P/1.slot" 2>/dev/null)" != "" ] || { [ -f "$P/1.slot" ] && [ "$(awk -F"|" "{print NF}" "$P/1.slot")" = 2 ]; }' \
    || fail "harness: the first holder never took a slot"
printf 'second|%s\n' "$other" > "$P/1.slot.new" && mv "$P/1.slot.new" "$P/1.slot"
wait "$first" 2>/dev/null
if grep -q '^second|' "$P/1.slot" 2>/dev/null; then ok "a holder's exit does not delete a slot someone else now holds"
else fail "the first holder's release deleted the second holder's slot (slot now: $(cat "$P/1.slot" 2>/dev/null || echo gone))"; fi

# 3. #125. Kill the wrapper with SIGKILL while its command runs. The slot
#    must still read held, and a second caller must not get it.
fresh
AM_SLOT_LIMIT=1 AM_SLOT_NAME=builder "$SLOT" p sh -c 'sleep 30' >/dev/null 2>&1 & wrapper=$!; pids+=("$wrapper")
wait_for '[ -f "$P/1.slot" ] && pgrep -f "sleep 30" >/dev/null' || fail "harness: the build never started"
kill -9 "$wrapper"; wait "$wrapper" 2>/dev/null
build=$(pgrep -f "^sleep 30$" | head -1)
[ -n "$build" ] && pids+=("$build")
if [ -n "$build" ]; then
    AM_SLOT_LIMIT=1 AM_SLOT_WAIT=0 AM_SLOT_NAME=second "$SLOT" p true >/dev/null 2>&1; rc=$?
    status=$(AM_SLOT_LIMIT=1 "$SLOT" --status p 2>&1)
    if [ "$rc" != 0 ] && printf '%s' "$status" | grep -q 'held by builder'; then
        ok "a killed wrapper's build still holds its slot, and a second caller is refused"
    else
        fail "the build outlived its wrapper but the slot was free (second caller rc=$rc; status: $(printf '%s' "$status" | tr '\n' ' '))"
    fi
    kill -9 "$build" 2>/dev/null
else
    fail "harness: the build died with its wrapper, so this check measured nothing"
fi

# 4. ACCEPTANCE: the command's exit status is the wrapper's, and a normal exit
#    releases the slot.
fresh
AM_SLOT_LIMIT=1 AM_SLOT_NAME=plain "$SLOT" p sh -c 'exit 7' >/dev/null 2>&1; rc=$?
[ "$rc" = 7 ] && ok "the command's exit status passes through" || fail "exit status: got $rc, expected 7"
[ -z "$(ls -A "$P" 2>/dev/null)" ] && ok "a normal exit releases the slot" || fail "a normal exit left: $(ls -A "$P")"

# 5. SIGTERM to the wrapper stops the work it is accounting for and releases.
fresh
AM_SLOT_LIMIT=1 AM_SLOT_NAME=stopped "$SLOT" p sh -c 'sleep 31' >/dev/null 2>&1 & wrapper=$!; pids+=("$wrapper")
wait_for 'pgrep -f "^sleep 31$" >/dev/null' || fail "harness: the command never started"
kill -TERM "$wrapper"; wait "$wrapper" 2>/dev/null
if wait_for '! pgrep -f "^sleep 31$" >/dev/null' && [ -z "$(ls -A "$P" 2>/dev/null)" ]; then
    ok "SIGTERM to the wrapper stops its command and releases the slot"
else
    fail "after SIGTERM: command alive=$(pgrep -f '^sleep 31$' >/dev/null && echo yes || echo no), slot files: $(ls -A "$P" | tr '\n' ' ')"
    pkill -9 -f '^sleep 31$' 2>/dev/null
fi

echo
if [ "$fails" = 0 ]; then
    echo "am-slot-holders: all checks passed"
else
    echo "am-slot-holders: $fails check(s) failed" >&2
fi
exit "$fails"
