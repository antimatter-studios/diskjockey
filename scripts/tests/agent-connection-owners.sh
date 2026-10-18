#!/usr/bin/env bash
# Connection ownership over the production bridge and lifecycle, plus the
# listener/queue wiring that must also hold in the built macOS helper.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
if "${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -pedantic \
    -I "$ROOT/DiskJockeyAgent" \
    "$ROOT/scripts/tests/fixtures/agent-connection-owners.cpp" -o "$SANDBOX/owners"; then
    if "$SANDBOX/owners"; then ok 'unique owners, foreign detach refusal and every owned disconnect';
    else fail 'connection ownership contract failed'; fi
else fail 'connection ownership registry does not build'; fi
if python3 - "$ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
listener = (root / 'DiskJockeyAgent/main.swift').read_text()
assert listener.index('setCodeSigningRequirement') < listener.index('DJAgentConnectionOpen()')
assert 'guard owner != 0 else { return false }' in listener
assert 'AgentImpl(ledger: ledger, owner: owner)' in listener
for handler in ('invalidationHandler', 'interruptionHandler'):
    assert re.search(r'conn\.' + handler + r' = \{ DJAgentConnectionDisconnect\(owner\) \}', listener)
assert listener.index('invalidationHandler') < listener.index('conn.resume()')
source = (root / 'DiskJockeyAgent/DJAgentConnections.cpp').read_text()
assert 'return dispatch_get_main_queue()' in source
assert 'dispatch_assert_queue(DJAgentConnectionQueue())' in source
assert 'dispatch_async(DJAgentConnectionQueue()' in source
assert 'DJAgentConnections().disconnect(owner)' in source
assert re.search(r'dispatch_source_create\(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,\s*DJAgentConnectionQueue\(\)\)', source)
header = (root / 'DiskJockeyAgent/DiskJockeyAgent-Bridging-Header.h').read_text()
assert '#include "DJAgentConnections.h"' in header
project = (root / 'DiskJockey.xcodeproj/project.pbxproj').read_text()
phase = re.search(r'DA9E17A0000000000000000C /\* Sources \*/ = \{(.*?)\n\t\t\};', project, re.S).group(1)
assert 'DJAgentConnections.cpp in Sources' in phase
assert (root / 'DiskJockeyAgent/DJAgentProtocol.swift').read_bytes() == (root / 'DiskJockeyApplication/Services/DJAgentProtocol.swift').read_bytes()
PY
then ok 'trusted listener binds both disconnect handlers and timers to the registry queue';
else fail 'listener ownership or queue wiring is missing'; fi
if [ "$fails" -eq 0 ]; then echo 'agent-connection-owners: all checks passed'; fi
exit "$((fails > 0))"
