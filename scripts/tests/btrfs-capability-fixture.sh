#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok/fail are the two arms; ok never fails
# The btrfs capability seed builder refuses to run without its independent
# builders, and CI builds and checks the seed with them (#492).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/btrfs-capability-fixture.sh"
CI="$ROOT/.github/workflows/ci.yml"
DOC="$ROOT/docs/constellation/cli-capability-checker.md"
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/none" "$sandbox/partial" "$sandbox/all" "$sandbox/existing"

[ -f "$SCRIPT" ] || { fail "missing $SCRIPT"; echo "btrfs-capability-fixture: $fails check(s) failed"; exit 1; }

# Stubs record any call: a refusal must happen before a builder runs.
stub() {
    # shellcheck disable=SC2016 # $0 belongs to the stub, not to this guard
    printf '#!/bin/sh\necho "$0" >> "%s/called"\nexit 0\n' "$sandbox" > "$1"
    chmod +x "$1"
}
stub "$sandbox/partial/mkfs.btrfs"
for t in mkfs.btrfs btrfs setfattr getfattr mount umount truncate sha256sum cmp mktemp; do
    stub "$sandbox/all/$t"
done

run() { # PATH, args...
    local p="$1"; shift
    rc=0
    PATH="$p" "$BASH" "$SCRIPT" "$@" > "$sandbox/out" 2> "$sandbox/err" || rc=$?
}

run "$sandbox/none" --dest "$sandbox/new-none"
missing_all=1
for t in mkfs.btrfs btrfs; do
    grep -q "missing $t; install btrfs-progs" "$sandbox/err" || missing_all=0
done
for t in setfattr getfattr; do
    grep -q "missing $t; install attr" "$sandbox/err" || missing_all=0
done
if [ "$rc" = 1 ] && [ "$missing_all" = 1 ]; then
    ok 'no builders: --dest fails naming btrfs-progs and attr for each'
else
    fail "no builders: --dest exited $rc: $(head -c 400 "$sandbox/err")"
fi
[ ! -e "$sandbox/new-none" ] && ok 'no builders: nothing created' || fail 'no builders: destination created'

run "$sandbox/partial" --dest "$sandbox/new-partial"
if [ "$rc" = 1 ] && grep -q 'missing btrfs; install btrfs-progs' "$sandbox/err" \
    && ! grep -q 'missing mkfs.btrfs' "$sandbox/err"; then
    ok 'partial builders: --dest names only the missing ones'
else
    fail "partial builders: --dest exited $rc: $(head -c 400 "$sandbox/err")"
fi
[ ! -e "$sandbox/new-partial" ] && [ ! -e "$sandbox/called" ] \
    && ok 'partial builders: nothing created or run' || fail 'partial builders: a builder ran or output appeared'

run "$sandbox/none" --check "$sandbox/existing"
if [ "$rc" = 1 ] && grep -q 'missing btrfs; install btrfs-progs' "$sandbox/err"; then
    ok 'no builders: --check fails naming btrfs-progs'
else
    fail "no builders: --check exited $rc"
fi

run "$sandbox/all" --dest "$sandbox/existing"
if [ "$rc" = 1 ] && grep -q 'exists; give a new directory' "$sandbox/err" && [ ! -e "$sandbox/called" ]; then
    ok 'existing destination is refused before any builder runs'
else
    fail "existing destination: exited $rc: $(head -c 400 "$sandbox/err")"
fi

run "$sandbox/all" --check "$sandbox/existing"
if [ "$rc" = 1 ] && grep -q 'build it with --dest' "$sandbox/err" && [ ! -e "$sandbox/called" ]; then
    ok '--check without a seed is refused'
else
    fail "--check without a seed: exited $rc"
fi

for args in '' '--dest' '--bogus x' '--dest a b'; do
    # shellcheck disable=SC2086
    run "$sandbox/none" $args
    [ "$rc" = 2 ] && ok "usage error for '$args'" || fail "'$args' exited $rc, expected 2"
done

grep -q 'apt-get install .*btrfs-progs' "$CI" \
    && ok 'CI installs btrfs-progs' || fail 'CI does not install btrfs-progs'
grep -q 'bash scripts/btrfs-capability-fixture.sh --dest ' "$CI" \
    && ok 'CI builds the seed with the independent tools' || fail 'CI does not build the btrfs seed'
grep -q 'bash scripts/btrfs-capability-fixture.sh --check ' "$CI" \
    && ok 'CI proves the executor gives every operation a fresh copy' || fail 'CI does not run the btrfs fresh-copy check'
grep -q 'scripts/btrfs-capability-fixture.sh' "$DOC" && grep -q 'Btrfs format limits' "$DOC" \
    && ok 'the checker documentation names the btrfs seed and its limits' \
    || fail 'the checker documentation does not describe the btrfs seed and its limits'

if [ "$fails" -gt 0 ]; then
    echo "btrfs-capability-fixture: $fails check(s) failed"
    exit 1
fi
echo 'btrfs-capability-fixture: all checks passed'
