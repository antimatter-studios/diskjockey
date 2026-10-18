#!/usr/bin/env bash
# The production agent loop is driven through a fake connection on the host.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
if "${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -pedantic \
    -I "$ROOT/DiskJockeyAgent" -I "$ROOT/DiskJockeyVirtualDisk" \
    "$ROOT/scripts/tests/fixtures/agent-read-loop.cpp" -o "$SANDBOX/loop"; then
    if "$SANDBOX/loop"; then ok 'authorized reads, errors, malformed requests and disconnects';
    else fail 'fake connection violated the serve-loop contract'; fi
else fail 'agent serve loop does not build'; fi
if grep -q 'AgentAuthority.attachableImage' "$ROOT/DiskJockeyAgent/AgentReadAuthority.swift"; then
    ok 'production authorization uses the caller-readable proof check'
else fail 'production loop is missing AgentAuthority'; fi
if python3 - "$ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
project = (root / 'DiskJockey.xcodeproj/project.pbxproj').read_text()
phase = re.search(r'DA9E17A0000000000000000C /\* Sources \*/ = \{(.*?)\n\t\t\};', project, re.S).group(1)
assert 'AgentReadAuthority.swift in Sources' in phase
assert 'DJAgentReadEndpoint.cpp in Sources' in phase
for configuration in ('0F', '10'):
    settings = re.search(r'DA9E17A000000000000000' + configuration + r' /\* (?:Debug|Release) \*/ = \{(.*?)\n\t\t\};', project, re.S).group(1)
    assert 'IOKit' in settings and '-ldj_agent_image_reader' in settings
source = (root / 'DiskJockeyAgent/DJAgentReadEndpoint.cpp').read_text()
assert 'DJAgentAuthorizeImage, openImage, dj_agent_image_read, dj_agent_image_close' in source
PY
then ok 'agent target compiles the connection and links IOKit and the host reader';
else fail 'agent target or authorization wiring is missing'; fi
if [ "$fails" -eq 0 ]; then echo 'agent-read-loop: all checks passed'; fi
exit "$((fails > 0))"
