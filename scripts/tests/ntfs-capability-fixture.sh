#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok/fail are the two arms; ok never fails
# The ntfs capability seed builder refuses to run without its independent
# builders, and CI builds and checks the seed with them (#490).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ntfs-capability-fixture.sh"
CI="$ROOT/.github/workflows/ci.yml"
DOC="$ROOT/docs/constellation/cli-capability-checker.md"
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/none" "$sandbox/partial" "$sandbox/all" "$sandbox/existing"

[ -f "$SCRIPT" ] || { fail "missing $SCRIPT"; echo "ntfs-capability-fixture: $fails check(s) failed"; exit 1; }

# Stubs record any call: a refusal must happen before a builder runs.
stub() {
    # shellcheck disable=SC2016 # $0 belongs to the stub, not to this guard
    printf '#!/bin/sh\necho "$0" >> "%s/called"\nexit 0\n' "$sandbox" > "$1"
    chmod +x "$1"
}
stub "$sandbox/partial/mkntfs"
for t in mkntfs ntfs-3g ntfscp ntfscat ntfsinfo ntfsls setfattr truncate sha256sum cmp mktemp; do
    stub "$sandbox/all/$t"
done

run() { # PATH, args...
    local p="$1"; shift
    rc=0
    PATH="$p" "$BASH" "$SCRIPT" "$@" > "$sandbox/out" 2> "$sandbox/err" || rc=$?
}

run "$sandbox/none" --dest "$sandbox/new-none"
missing_all=1
for t in mkntfs ntfs-3g ntfscp ntfscat ntfsinfo ntfsls; do
    grep -q "missing $t; install ntfs-3g" "$sandbox/err" || missing_all=0
done
grep -q 'missing setfattr; install attr' "$sandbox/err" || missing_all=0
if [ "$rc" = 1 ] && [ "$missing_all" = 1 ]; then
    ok 'no builders: --dest fails naming ntfs-3g and attr for each'
else
    fail "no builders: --dest exited $rc: $(head -c 400 "$sandbox/err")"
fi
[ ! -e "$sandbox/new-none" ] && ok 'no builders: nothing created' || fail 'no builders: destination created'

run "$sandbox/partial" --dest "$sandbox/new-partial"
if [ "$rc" = 1 ] && grep -q 'missing ntfscat; install ntfs-3g' "$sandbox/err" \
    && ! grep -q 'missing mkntfs' "$sandbox/err"; then
    ok 'partial builders: --dest names only the missing ones'
else
    fail "partial builders: --dest exited $rc: $(head -c 400 "$sandbox/err")"
fi
[ ! -e "$sandbox/new-partial" ] && [ ! -e "$sandbox/called" ] \
    && ok 'partial builders: nothing created or run' || fail 'partial builders: a builder ran or output appeared'

run "$sandbox/none" --check "$sandbox/existing"
if [ "$rc" = 1 ] && grep -q 'missing ntfscp; install ntfs-3g' "$sandbox/err"; then
    ok 'no builders: --check fails naming ntfs-3g'
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

grep -q 'apt-get install .*ntfs-3g' "$CI" \
    && ok 'CI installs ntfs-3g' || fail 'CI does not install ntfs-3g'
grep -q 'bash scripts/ntfs-capability-fixture.sh --dest ' "$CI" \
    && ok 'CI builds the seed with the independent tools' || fail 'CI does not build the ntfs seed'
grep -q 'bash scripts/ntfs-capability-fixture.sh --check ' "$CI" \
    && ok 'CI proves the executor gives every operation a fresh copy' || fail 'CI does not run the ntfs fresh-copy check'
grep -q 'scripts/ntfs-capability-fixture.sh' "$DOC" && grep -q 'NTFS format limits' "$DOC" \
    && ok 'the checker documentation names the ntfs seed and its limits' \
    || fail 'the checker documentation does not describe the ntfs seed and its limits'

if [ "$fails" -gt 0 ]; then
    echo "ntfs-capability-fixture: $fails check(s) failed"
    exit 1
fi
echo 'ntfs-capability-fixture: all checks passed'
