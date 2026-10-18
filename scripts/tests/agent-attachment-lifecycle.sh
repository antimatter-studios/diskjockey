#!/usr/bin/env bash
# Drive the agent's production ownership lifecycle without platform fixtures.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
if "${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -pedantic \
    -I "$ROOT/DiskJockeyAgent" \
    "$ROOT/scripts/tests/fixtures/agent-attachment-lifecycle.cpp" -o "$SANDBOX/lifecycle"; then
    if "$SANDBOX/lifecycle"; then ok 'owned media, active deadlines and ordered asynchronous cleanup';
    else fail 'attachment ownership lifecycle contract failed'; fi
else fail 'agent attachment lifecycle does not build'; fi
if [ "$fails" -eq 0 ]; then echo 'agent-attachment-lifecycle: all checks passed'; fi
exit "$((fails > 0))"
