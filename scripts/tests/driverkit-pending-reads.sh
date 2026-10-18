#!/usr/bin/env bash
# Exercise the pending lifecycle with a fake endpoint and an active fake timer.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
compiler="${CXX:-c++}"
if ! command -v "$compiler" >/dev/null 2>&1; then
    fail 'C++ compiler missing; install the toolchain for check:scripts'
elif "$compiler" -std=c++17 -Wall -Wextra -Werror -pedantic \
    -I "$ROOT/DiskJockeyVirtualDisk" \
    "$ROOT/scripts/tests/fixtures/driverkit-pending-reads.cpp" -o "$SANDBOX/pending"; then
    if "$SANDBOX/pending"; then ok 'pending reads finish once and publish only complete payloads';
    else fail 'pending lifecycle violated a fake endpoint or timer case'; fi
else
    fail 'pending read lifecycle does not build'
fi
if [ "$fails" -eq 0 ]; then echo 'driverkit-pending-reads: all checks passed'; fi
exit "$((fails > 0))"
