#!/usr/bin/env bash
# Drive the agent bridge's publish and remove hooks over an injected
# user-client connection: publication is the dext's mount selector and
# removal its unmount selector, and every failure (mount selector, appearance
# timeout, disk unmount, unmount selector) enters the attachment cleanup with
# the reader and connection closed only after a successful removal.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
if "${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -pedantic \
    -I "$ROOT/DiskJockeyAgent" \
    "$ROOT/scripts/tests/fixtures/agent-bridge-mount-selectors.cpp" -o "$SANDBOX/bridge"; then
    if "$SANDBOX/bridge"; then ok 'publish and remove call the dext selectors; every failure enters cleanup';
    else fail 'agent bridge mount-selector contract failed'; fi
else fail 'agent bridge mount selectors do not build'; fi
if [ "$fails" -eq 0 ]; then echo 'agent-bridge-mount-selectors: all checks passed'; fi
exit "$((fails > 0))"
