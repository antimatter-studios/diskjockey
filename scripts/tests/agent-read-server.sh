#!/usr/bin/env bash
# The agent answers dext read requests through a fake authorized image reader.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
for language in c c++; do
    if [ "$language" = c ]; then compiler="${CC:-cc}"; standard=c11;
    else compiler="${CXX:-c++}"; standard=c++17; fi
    if ! command -v "$compiler" >/dev/null 2>&1; then
        fail "$language compiler missing; install the toolchain for check:scripts"
    elif "$compiler" -x "$language" -std="$standard" -Wall -Wextra -Werror -pedantic \
        -I "$ROOT/DiskJockeyAgent" -I "$ROOT/DiskJockeyVirtualDisk" \
        "$ROOT/scripts/tests/fixtures/agent-read-server.c" -o "$SANDBOX/server-$language"; then
        if "$SANDBOX/server-$language"; then ok "$language agent replies only with complete reads";
        else fail "$language agent read server violated a fake reader case"; fi
    else
        fail "$language agent read server does not build"
    fi
done
if [ "$fails" -eq 0 ]; then echo 'agent-read-server: all checks passed'; fi
exit "$((fails > 0))"
