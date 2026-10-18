#!/usr/bin/env bash
# The host-side reader ABI must compile before its CI fixture oracle runs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
for language in c c++; do
    if [ "$language" = c ]; then compiler="${CC:-cc}"; standard=c11;
    else compiler="${CXX:-c++}"; standard=c++17; fi
    if printf '#include "DJAgentImageReader.h"\n' | "$compiler" -x "$language" -std="$standard" -Wall -Wextra -Werror -pedantic -fsyntax-only -I "$ROOT/DiskJockeyAgent" -; then
        printf 'ok    %s host reader ABI compiles\n' "$language"
    else
        printf 'FAIL  %s host reader ABI is missing or invalid\n' "$language"
        fails=$((fails + 1))
    fi
done
[ "$fails" -ne 0 ] || echo 'agent-vhdx-reader: all checks passed'
exit "$((fails > 0))"
