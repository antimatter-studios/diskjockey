#!/usr/bin/env bash
# Drive the agent's production DiskArbitration media matcher over a fake
# IOMedia ancestry: only the owned attachment identity yields a device.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
if "${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -pedantic \
    -I "$ROOT/DiskJockeyAgent" \
    "$ROOT/scripts/tests/fixtures/agent-media-correlation.cpp" -o "$SANDBOX/correlation"; then
    if "$SANDBOX/correlation"; then ok 'only whole media with the owned ancestry identity returns a BSD device';
    else fail 'agent media correlation contract failed'; fi
else fail 'agent media correlation does not build'; fi
if [ "$fails" -eq 0 ]; then echo 'agent-media-correlation: all checks passed'; fi
exit "$((fails > 0))"
