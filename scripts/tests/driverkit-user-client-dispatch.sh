#!/usr/bin/env bash
# The user-client dispatch core checks every external method before pending state.
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
    "$ROOT/scripts/tests/fixtures/driverkit-user-client-dispatch.cpp" -o "$SANDBOX/dispatch"; then
    if "$SANDBOX/dispatch"; then ok 'external methods carry exact replies and refuse every other shape';
    else fail 'user-client dispatch violated a fake endpoint case'; fi
else
    fail 'user-client dispatch core does not build'
fi
if [ "$fails" -eq 0 ]; then echo 'driverkit-user-client-dispatch: all checks passed'; fi
exit "$((fails > 0))"
