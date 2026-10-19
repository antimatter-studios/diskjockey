#!/usr/bin/env bash
# The agent's qcow2 open must compile beside VHDX before its CI fixture oracle runs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
probe='#include "DJAgentImageReader.h"
static DJAgentImageReader *(*const open_qcow2)(int, DJAgentImageGeometry *) = dj_agent_qcow2_open;
int main(void) { return open_qcow2 == 0; }'
for language in c c++; do
    if [ "$language" = c ]; then compiler="${CC:-cc}"; standard=c11;
    else compiler="${CXX:-c++}"; standard=c++17; fi
    if printf '%s\n' "$probe" | "$compiler" -x "$language" -std="$standard" -Wall -Wextra -Werror -pedantic -fsyntax-only -I "$ROOT/DiskJockeyAgent" - 2>/dev/null; then
        ok "$language host reader declares dj_agent_qcow2_open"
    else
        fail "$language host reader does not declare dj_agent_qcow2_open"
    fi
done
check() {
    if grep -q "$1" "$2"; then ok "$3"; else fail "$4"; fi
}
check 'dj_agent_qcow2_open' "$ROOT/DiskJockeyAgent/DJAgentReadEndpoint.cpp" \
    "the read endpoint opens qcow2 images" "the read endpoint opens only VHDX images"
check 'rust-img-qcow2' "$ROOT/rust-bundles/dj-agent-image-reader/Cargo.toml" \
    "the agent reader links the published qcow2 reader" "the agent reader does not depend on rust-img-qcow2"
check 'agent-qcow2-oracle.sh' "$ROOT/.github/workflows/ci.yml" \
    "CI runs the qcow2 oracle" "CI does not run scripts/agent-qcow2-oracle.sh"
[ "$fails" -ne 0 ] || echo 'agent-qcow2-reader: all checks passed'
exit "$((fails > 0))"
