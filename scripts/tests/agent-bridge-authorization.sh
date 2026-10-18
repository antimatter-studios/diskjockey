#!/usr/bin/env bash
# Drive the agent's production attachment bridge over injected platform
# boundaries: authorization precedes dext discovery and endpoint opening, and
# every resource closes exactly once, only after removal.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
if "${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -pedantic \
    -I "$ROOT/DiskJockeyAgent" \
    "$ROOT/scripts/tests/fixtures/agent-bridge-authorization.cpp" -o "$SANDBOX/bridge"; then
    if "$SANDBOX/bridge"; then ok 'authorization precedes discovery and opening; resources close only after removal';
    else fail 'agent bridge authorization contract failed'; fi
else fail 'agent bridge authorization does not build'; fi
if [ "$fails" -eq 0 ]; then echo 'agent-bridge-authorization: all checks passed'; fi
exit "$((fails > 0))"
