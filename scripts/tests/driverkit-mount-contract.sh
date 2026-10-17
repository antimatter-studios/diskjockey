#!/usr/bin/env bash
# The recovered mount ABI and its bounds checks must work for both the host
# (C-compatible imports) and the DriverKit user client (C++).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

for language in c c++; do
    if [ "$language" = c ]; then
        compiler="${CC:-cc}"
        standard=c11
    else
        compiler="${CXX:-c++}"
        standard=c++17
    fi
    if ! command -v "$compiler" >/dev/null 2>&1; then
        fail "$language compiler is missing; install the C/C++ toolchain for check:scripts"
        continue
    fi
    if "$compiler" -x "$language" -std="$standard" -Wall -Wextra -Werror -pedantic \
        -I "$ROOT/DiskJockeyVirtualDisk" \
        "$ROOT/scripts/tests/fixtures/driverkit-mount-contract.c" \
        -o "$SANDBOX/contract"; then
        if "$SANDBOX/contract"; then
            ok "$language preserves the ABI and validates virtual geometry"
        else
            fail "$language mount contract rejects a required boundary case"
        fi
    else
        fail "$language mount contract does not build"
    fi
done

if [ "$fails" -eq 0 ]; then
    echo 'driverkit-mount-contract: all checks passed'
else
    echo "driverkit-mount-contract: $fails check(s) failed" >&2
fi
exit "$((fails > 0))"
