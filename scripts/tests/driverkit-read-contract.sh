#!/usr/bin/env bash
# The shared read wire contract must work in both the host and the dext.
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
        continue
    fi
    if "$compiler" -x "$language" -std="$standard" -Wall -Wextra -Werror -pedantic \
        -I "$ROOT/DiskJockeyVirtualDisk" -I "$ROOT/DiskJockeyAgent" \
        "$ROOT/scripts/tests/fixtures/driverkit-read-contract.c" -o "$SANDBOX/contract"; then
        if "$SANDBOX/contract"; then ok "$language read ABI and bounded request/reply checks";
        else fail "$language read contract rejected a required boundary case"; fi
    else
        fail "$language read contract does not build"
    fi
done
if [ "$fails" -eq 0 ]; then echo 'driverkit-read-contract: all checks passed';
else echo "driverkit-read-contract: $fails check(s) failed" >&2; fi
exit "$((fails > 0))"
