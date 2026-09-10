#!/usr/bin/env bash
#
# am-ledger-lock.sh — a removal removes the generation it was authorised
# against, or nothing.
#
# `with_lock`'s three removals were all `rm -rf "$LOCK"`, against a lock
# directory that recorded nothing about who held it. So the stale break
# removed whatever was at the path rather than the lock whose age it had
# measured, and two waiters agreeing that one holder was stale gave: the
# first breaks and acquires, the second's `rm` deletes the first's lock,
# and both run a read-modify-write on the ledger. That is the lost
# update the function exists to prevent.
#
# WHY THIS TESTS THE FUNCTIONS AND NOT THE CLI. The defect is a
# check-then-act crossing. Driving one through the CLI can only be
# RACED, and a racing test passes on a quiet machine and says nothing —
# which is the shape this repository's own pipeline doc warns about. So
# `am-ledger` is sourced with `AM_LEDGER_SOURCED=1` and the removals are
# called directly, which turns the crossing into an assertion.
#
#   bash scripts/tests/am-ledger-lock.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
export AM_LEDGER_DIR="$sandbox"

AM_LEDGER_SOURCED=1 . "$REPO/scripts/am-ledger"
# SOURCING IMPORTS THE SCRIPT'S OWN `set -euo pipefail`, so `-e` is now
# on in here whatever this file declared above. Every check below is a
# deliberate test of a failing command, and under `-e` the first one
# ends the run — which showed up as this file stopping silently after
# check 7 with no summary line and no failure named. Restore what this
# file asked for.
set +e

ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3: expected [$2], got [$1]"; fi; }

# A lock directory whose record names $1 as its token and $2 as its
# creation epoch.
plant() {
    rm -rf "$LOCK"
    mkdir -p "$LOCK"
    printf '%s\t%s\t%s\n' "$$" "$2" "$1" > "$LOCK_HOLDER"
}

echo "am-ledger-lock: the removals"

# 1. THE DEFECT. A holder's token is read, the lock is replaced by a
#    different generation, and the removal must refuse — because what is
#    in front of it is not what was measured.
plant "generation-A" "$(now_epoch)"
seen="$(lock_field 3)"
check "$seen" "generation-A" "the token a waiter reads is the one that was written"
plant "generation-B" "$(now_epoch)"
if lock_remove_generation "$seen"; then
    bad "a removal authorised against generation-A deleted generation-B"
else
    ok "a removal refuses a generation it was not authorised against"
fi
check "$(lock_field 3)" "generation-B" "and generation-B's lock is still there"

# 2. ACCEPTANCE. The mechanism has to still work, or the fix is a
#    deadlock rather than a lock.
if lock_remove_generation "generation-B"; then
    ok "a removal authorised against the generation in front of it succeeds"
else
    bad "the removal refused the generation it was authorised against"
fi
[ -e "$LOCK" ] && bad "the lock survived its own removal" || ok "and the lock is gone"

# 3. NO TOKEN, NO REMOVAL. An empty token must not act as a wildcard;
#    that is how `LOCK_TOKEN=""` before the first acquire would have
#    deleted a live lock on exit.
plant "generation-C" "$(now_epoch)"
if lock_remove_generation ""; then
    bad "an empty token removed a live lock"
else
    ok "an empty token removes nothing"
fi
check "$(lock_field 3)" "generation-C" "generation-C is untouched"

# 4. A RECORD WITH NO TABS IS NOT A RECORD. `cut -f` returns the whole
#    line for every field index on a line carrying no tab, so a holder
#    file reading `generation-C` would answer `generation-C` to a
#    request for the token and authorise its own removal.
rm -rf "$LOCK"; mkdir -p "$LOCK"; printf 'generation-C\n' > "$LOCK_HOLDER"
if lock_record >/dev/null 2>&1; then
    bad "a single-field line was accepted as a holder record"
else
    ok "a line with no tabs is not a holder record"
fi
if lock_remove_generation "generation-C"; then
    bad "a tab-less line authorised a removal by matching every field"
else
    ok "and it authorises no removal"
fi

# 5. THE RECORDLESS LOCK IS BREAKABLE, or a lock written by the previous
#    version of this script strands every project's ledger forever.
rm -rf "$LOCK"; mkdir -p "$LOCK"
if lock_remove_recordless; then
    ok "a lock recording no holder can be broken"
else
    bad "a recordless lock could not be broken; an upgrade would strand the ledger"
fi
[ -e "$LOCK" ] && bad "the recordless lock survived" || ok "and it is gone"

# 6. BUT NOT ONCE IT HAS A RECORD. An acquirer between its `mkdir` and
#    its write looks exactly like a pre-upgrade lock; the difference is
#    re-checked immediately before the rename.
plant "generation-D" "$(now_epoch)"
if lock_remove_recordless; then
    bad "the recordless break deleted a lock that had a record"
else
    ok "the recordless break refuses a lock that has a record"
fi
check "$(lock_field 3)" "generation-D" "generation-D is untouched"

# 7. THE EXIT TRAP IS BOUND TOO — the site most easily left behind. A
#    trap that removes `$LOCK` deletes whoever holds it at exit, not
#    whoever set the trap. Run a real `with_lock` whose command replaces
#    the lock with another generation, then check the other generation
#    survived the trap.
rm -rf "$LOCK"
crossing() { plant "generation-E" "$(now_epoch)"; }
( with_lock crossing ) >/dev/null 2>&1 || true
if [ -e "$LOCK" ] && [ "$(lock_field 3 2>/dev/null || true)" = "generation-E" ]; then
    ok "with_lock's exit path leaves a generation it does not hold alone"
else
    bad "with_lock removed generation-E, which it never held"
fi

# 7b. AND THE TRAP FIRES ON THE ABNORMAL EXIT, which is the only path
#     that reaches it — a `with_lock` that returns normally releases and
#     then disarms the trap, so test 7 above exercises the RELEASE and
#     says nothing about the trap.
#
#     `exit`, NOT `return 1`. The first version of this used `return 1`
#     and relied on `set -e` aborting `with_lock`; the `set +e` above
#     had switched that off, so the function ran to its normal release
#     and disarmed the trap, and this check silently tested the release
#     for a second time. It was caught because two arms disagreed:
#     reverting the RELEASE to an unbound `rm` failed this check and
#     reverting the TRAP did not, which cannot both be true of a check
#     that reaches the trap. An `exit` inside the subshell ends it and
#     the EXIT trap is what runs.
rm -rf "$LOCK"
crossing_then_die() { plant "generation-H" "$(now_epoch)"; exit 1; }
( with_lock crossing_then_die ) >/dev/null 2>&1 || true
if [ -e "$LOCK" ] && [ "$(lock_field 3 2>/dev/null || true)" = "generation-H" ]; then
    ok "the exit trap leaves a generation it does not hold alone"
else
    bad "the exit trap removed generation-H, which with_lock never held"
fi

# 7c. AN EMPTY TOKEN AGAINST A RECORDLESS LOCK. This is where the
#     `[ -n "$want" ]` guard is load-bearing and nowhere else: with a
#     record present an empty token simply fails the comparison, but in
#     front of a lock that records nothing, `lock_field 3` is also
#     empty and the two would match. That is the state `LOCK_TOKEN=""`
#     is in before the first acquire and after every release.
rm -rf "$LOCK"; mkdir -p "$LOCK"
if lock_remove_generation ""; then
    bad "an empty token removed a recordless lock by matching its empty token"
else
    ok "an empty token does not match a lock that records nothing"
fi
[ -e "$LOCK" ] || bad "the recordless lock was removed by an empty token"

# 7d. THE BREAK'S CROSSING, DRIVEN RATHER THAN READ.
#
#     This was a check on the SOURCE — that `with_lock`'s body contains
#     no `rm -rf "$LOCK"` — on the stated grounds that the break site
#     could not be driven into a crossing without racing. It can, so it
#     is, and the source check is gone: a behavioural check that names
#     the surviving generation is worth more than a grep.
#
#     `lock_field 1` is read for the announcement, which happens AFTER
#     the staleness decision and BEFORE the removal. Stubbing it is
#     therefore an interposition at exactly the point the defect lives:
#     the lock the decision measured is replaced by a live one, and a
#     removal bound to the measured token must refuse.
#
#     THE THRESHOLD HAS TO BE ONE ONLY THE PLANTED LOCK EXCEEDS. With a
#     small `LOCK_STALE_SECS` the swapped-in generation is instantly
#     stale too and the next iteration breaks it legitimately, so both
#     arms agree and the harness proves nothing. Planted at two hours
#     old against a ten-minute threshold, the replacement is age 0.
rm -rf "$LOCK"
plant "generation-OLD" "$(( $(now_epoch) - 7200 ))"
LOCK_STALE_SECS=600
crossed=0
lock_field() {
    local n="$1" line
    [ -f "$LOCK_HOLDER" ] || return 1
    IFS= read -r line < "$LOCK_HOLDER" 2>/dev/null || return 1
    if [ "$n" = 1 ] && [ "$crossed" = 0 ]; then
        crossed=1
        plant "generation-NEW" "$(now_epoch)"
        IFS= read -r line < "$LOCK_HOLDER" 2>/dev/null || return 1
    fi
    printf '%s\n' "$line" | awk -F'\t' -v k="$n" '{print $k}'
}
# `with_lock` cannot acquire — the replacement is live and young — so it
# is bounded rather than waited on. The break happens on the first
# iteration, about 0.2s in.
( with_lock true ) >/dev/null 2>&1 &
bg=$!
sleep 2
kill "$bg" 2>/dev/null
wait "$bg" 2>/dev/null
unset -f lock_field
AM_LEDGER_SOURCED=1 . "$REPO/scripts/am-ledger"
set +e
# Read the holder file directly: the stub is gone, and this must not
# depend on the function it was interposing on.
survivor="$(awk -F'\t' '{print $3}' "$LOCK_HOLDER" 2>/dev/null)"
if [ "$survivor" = "generation-NEW" ]; then
    ok "a break refuses the live generation that replaced the one it measured"
else
    bad "the break destroyed generation-NEW, which it never measured (found [$survivor])"
fi
LOCK_STALE_SECS="${AM_LEDGER_STALE_SECS:-60}"

# 8. THE DECISION FOLLOWS THE RECORD, NOT HOW LONG WE WAITED. `waited`
#    measures how long WE have queued, which says nothing about the age
#    of the lock in front of us; the old code broke on `waited` alone,
#    so a lock created one tick ago was removed by a waiter that had
#    been queuing longer than the threshold.
rm -rf "$LOCK"
plant "generation-F" "$(now_epoch)"
out="$(AM_LEDGER_STALE_SECS=3600 timeout 3 "$REPO/scripts/am-ledger" set demo 1 stage=fixing 2>&1)" || true
if printf '%s' "$out" | grep -q 'breaking'; then
    bad "a healthy lock was broken after enough waiting: $out"
else
    ok "waiting does not make a healthy lock stale"
fi
check "$(lock_field 3)" "generation-F" "generation-F still holds the lock"

# 9. ACCEPTANCE FOR THE BREAK PATH. A lock whose OWN record is old is
#    broken, and the command then runs — otherwise a dead holder wedges
#    the ledger permanently, which is what the break is for.
rm -rf "$LOCK"
plant "generation-G" "$(( $(now_epoch) - 7200 ))"
printf 'demo\t1\taccepted\t-\t-\t-\t2026-01-01T00:00:00Z\ta row\n' > "$LEDGER"
out="$(AM_LEDGER_STALE_SECS=60 timeout 10 "$REPO/scripts/am-ledger" set demo 1 stage=fixing 2>&1)" || true
if printf '%s' "$out" | grep -q 'breaking a lock held by pid'; then
    ok "a lock whose record is old is broken, and it says whose it was"
else
    bad "an old lock was not broken: $out"
fi
if awk -F'\t' '$1=="demo" && $2=="1" && $3=="fixing"' "$LEDGER" | grep -q .; then
    ok "and the write it was holding up went through"
else
    bad "the break happened but the write did not: $(cat "$LEDGER")"
fi

# 10. THE RECORDLESS BREAK IS REACHED FROM `with_lock`, AND WITHOUT IT
#     THE LEDGER STRANDS.
#
#     Check 5 calls `lock_remove_recordless` directly. That says the
#     function works and nothing about whether `with_lock` ever calls
#     it — disabling the call left every check green. The discrimination
#     is not subtle: with the call, the pre-upgrade lock is broken and
#     the command runs; without it, `with_lock` NEVER RETURNS. That
#     strand IS the upgrade-safety property this branch claims, because
#     the previous version of this script wrote no holder record at all.
rm -rf "$LOCK"
mkdir -p "$LOCK"          # a lock exactly as the old version left it
LOCK_RECORDLESS_GRACE_SECS=1
ran="$sandbox/recordless-ran"
rm -f "$ran"
touch_marker() { : > "$ran"; }
( with_lock touch_marker ) >/dev/null 2>&1 &
bg=$!
n=0
while [ $n -lt 60 ] && kill -0 "$bg" 2>/dev/null; do sleep 0.2; n=$((n + 1)); done
if kill -0 "$bg" 2>/dev/null; then
    kill "$bg" 2>/dev/null; wait "$bg" 2>/dev/null
    bad "with_lock never returned in front of a lock recording no holder: the ledger is stranded"
else
    wait "$bg" 2>/dev/null
    if [ -f "$ran" ]; then
        ok "with_lock breaks a lock that records no holder and runs the command"
    else
        bad "with_lock returned but the command never ran"
    fi
fi
LOCK_RECORDLESS_GRACE_SECS="${AM_LEDGER_RECORDLESS_GRACE:-5}"

# 11. ONE ANNOUNCEMENT PER GENERATION.
#
#     The staleness decision is made from the record's own age, so a
#     lock that is old is old on every iteration and the break is
#     attempted every 0.2s for as long as it persists. The attempts are
#     harmless — each refuses unless the token still matches — but the
#     LOG is not: the first version of this change tried to rate-limit
#     with `waited=0`, which cannot work against an age-based decision,
#     and a mutation deleting it left every check green because it did
#     nothing. What is rate-limited now is the announcement, keyed on
#     the generation, and this counts them.
rm -rf "$LOCK"
plant "generation-NOISY" "$(( $(now_epoch) - 7200 ))"
LOCK_STALE_SECS=600
# The removal always fails, so the same stale lock stays in front of the
# waiter and the loop keeps deciding it is stale. Without the keyed
# announcement that is one line of log per 0.2s.
lock_remove_generation() { return 1; }
noise="$sandbox/announcements"
( with_lock true ) 2>"$noise" >/dev/null &
bg=$!
sleep 2
kill "$bg" 2>/dev/null
wait "$bg" 2>/dev/null
unset -f lock_remove_generation
AM_LEDGER_SOURCED=1 . "$REPO/scripts/am-ledger"
set +e
said="$(grep -c 'breaking a lock held by pid' "$noise" 2>/dev/null || echo 0)"
if [ "$said" = 1 ]; then
    ok "a stale generation is announced once, not once per 0.2s (said $said)"
else
    bad "the break announced itself $said times for one generation over 2s"
fi
LOCK_STALE_SECS="${AM_LEDGER_STALE_SECS:-60}"

# 12. THE RECORDLESS GRACE COUNTS FROM WHEN A RECORDLESS LOCK IS SEEN,
#     NOT FROM WHEN WE STARTED QUEUING.
#
#     Every recordless check above starts from a LONE recordless lock,
#     which is the control: it gets its declared grace. The case none of
#     them can see is a recordless lock that appears AFTER a wait — and
#     that is the mixed-version upgrade window the recordless path
#     exists for, because a lock recording nothing IS an old-version
#     holder.
#
#     Driven with a stubbed `lock_field`: a stale RECORDED lock whose
#     removal always refuses, then the record vanishing. With the grace
#     borrowed from the loop's own counter the recordless lock was
#     broken on the first iteration it was seen — zero grace, the unsafe
#     direction.
#
#     THE OBSERVABLE IS AN ITERATION COUNT, NOT A CLOCK. The stub
#     appends to a FILE rather than incrementing a variable, because
#     `lock_field` is called inside `$( )` and a counter incremented in
#     a subshell never persists — such a harness reports nothing at all
#     rather than a wrong number.
rm -rf "$LOCK"
plant "generation-STALE" "$(( $(now_epoch) - 7200 ))"
LOCK_STALE_SECS=600
LOCK_RECORDLESS_GRACE_SECS=2          # 10 ticks
calls="$sandbox/field-calls"
vanish="$sandbox/vanished"
broke="$sandbox/broke-at"
rm -f "$calls" "$vanish" "$broke"
lock_field() {
    local n="$1" line
    echo x >> "$calls"
    # After 15 ticks in front of the recorded lock, the record vanishes
    # and a bare directory is left — exactly an old-version holder.
    if [ "$(wc -l < "$calls" | tr -d ' ')" -gt 15 ] && [ ! -f "$vanish" ]; then
        wc -l < "$calls" | tr -d ' ' > "$vanish"
        rm -rf "$LOCK"; mkdir -p "$LOCK"
    fi
    [ -f "$LOCK_HOLDER" ] || return 1
    IFS= read -r line < "$LOCK_HOLDER" 2>/dev/null || return 1
    printf '%s\n' "$line" | awk -F'\t' -v k="$n" '{print $k}'
}
lock_remove_generation() { return 1; }
# THE FIRST FIRE, NOT THE LAST. This wrote `$broke` on every call, so
# it recorded the LAST break rather than the first -- and with the grace
# removed the branch fires on every iteration, which made the measured
# gap LARGER and the check pass. Both arms agreed when the evidence said
# they should not, which is the harness rather than the code.
lock_remove_recordless() {
    [ -f "$broke" ] || wc -l < "$calls" | tr -d ' ' > "$broke"
    return 1
}
( with_lock true ) >/dev/null 2>&1 &
bg=$!
sleep 6
kill "$bg" 2>/dev/null
wait "$bg" 2>/dev/null
unset -f lock_field lock_remove_generation lock_remove_recordless
AM_LEDGER_SOURCED=1 . "$REPO/scripts/am-ledger"
set +e
if [ -f "$vanish" ] && [ -f "$broke" ]; then
    gap=$(( $(cat "$broke") - $(cat "$vanish") ))
    if [ "$gap" -ge 10 ]; then
        ok "a recordless lock seen after a wait still gets its full grace ($gap ticks)"
    else
        bad "the recordless lock was broken $gap ticks after the record vanished; its grace is 10"
    fi
else
    bad "the harness did not reach the recordless branch (vanished=$([ -f "$vanish" ] && cat "$vanish")) (broke=$([ -f "$broke" ] && cat "$broke"))"
fi
LOCK_STALE_SECS="${AM_LEDGER_STALE_SECS:-60}"
LOCK_RECORDLESS_GRACE_SECS="${AM_LEDGER_RECORDLESS_GRACE:-5}"

echo
if [ "$fails" = 0 ]; then
    echo "am-ledger-lock: all checks passed"
else
    echo "am-ledger-lock: $fails check(s) failed" >&2
fi
exit "$fails"
