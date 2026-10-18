#!/usr/bin/env bash
# Drive the dext's production block-I/O core over a fake read backend: reads
# map LBAs through the partition offset with overflow-checked bounds, writes,
# unmap and empty requests never reach the backend, and every accepted read
# completes exactly once, with an error rather than zero-filled bytes.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
if "${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -pedantic \
    -I "$ROOT/DiskJockeyVirtualDisk" \
    "$ROOT/scripts/tests/fixtures/dext-block-io.cpp" -o "$SANDBOX/block-io"; then
    if "$SANDBOX/block-io"; then ok 'block reads apply the partition offset, refuse writes and complete once';
    else fail 'dext block I/O contract failed'; fi
else fail 'dext block I/O core does not build'; fi
if [ "$fails" -eq 0 ]; then echo 'dext-block-io: all checks passed'; fi
exit "$((fails > 0))"
