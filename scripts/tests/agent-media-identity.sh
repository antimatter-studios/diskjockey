#!/usr/bin/env bash
# Drive the agent's production registry identity search over a fake IOKit
# registry: the identity comes only from a non-zero number property found on
# the media's ancestry, and every object the search copies is released.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
if "${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -pedantic \
    -I "$ROOT/DiskJockeyAgent" \
    "$ROOT/scripts/tests/fixtures/agent-media-identity.cpp" -o "$SANDBOX/identity"; then
    if "$SANDBOX/identity"; then ok 'the ancestry search yields only a non-zero number identity and releases every copy';
    else fail 'agent media identity contract failed'; fi
else fail 'agent media identity search does not build'; fi
if [ "$fails" -eq 0 ]; then echo 'agent-media-identity: all checks passed'; fi
exit "$((fails > 0))"
