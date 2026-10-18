#!/usr/bin/env bash
# Drive the dext's production mount-selector core over a fake read backend and
# child publisher: arguments are checked first, slots are bounded and reserved
# before publication, and a failed publication or removal leaks nothing.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
if "${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -pedantic \
    -I "$ROOT/DiskJockeyVirtualDisk" \
    "$ROOT/scripts/tests/fixtures/dext-mount-selectors.cpp" -o "$SANDBOX/selectors"; then
    if "$SANDBOX/selectors"; then ok 'mount selectors check arguments and hold bounded, reserved slots';
    else fail 'dext mount selector contract failed'; fi
else fail 'dext mount selectors do not build'; fi
if [ "$fails" -eq 0 ]; then echo 'dext-mount-selectors: all checks passed'; fi
exit "$((fails > 0))"
