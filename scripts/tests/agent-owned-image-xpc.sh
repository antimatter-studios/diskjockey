#!/usr/bin/env bash
# The owned DriverKit route crosses XPC; platform APIs stay in the helper.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
if python3 - "$ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
def read(name): return (root / name).read_text()
protocol = read('DiskJockeyAgent/DJAgentProtocol.swift')
assert protocol == read('DiskJockeyApplication/Services/DJAgentProtocol.swift')
for method in ('attachDriverKitImage', 'detachDriverKitImage'):
    assert 'func ' + method + '(' in protocol, method + ' missing from XPC'
assert 'attachmentID: UInt64' in protocol
assert 'owner:' not in protocol, 'the XPC caller must never choose its owner'
agent = read('DiskJockeyAgent/AgentImpl.swift')
assert 'DJAgentOwnedImageAttach(owner,' in agent
assert 'DJAgentOwnedImageDetach(owner,' in agent
assert 'try? proof.close()' in agent
client = read('DiskJockeyApplication/Services/DJAgentClient.swift')
for method in ('attachDriverKitImage', 'detachDriverKitImage'):
    assert 'proxy.' + method + '(' in client
caller = read('DiskJockeyApplication/Services/DriverKitImageAttachment.swift')
assert 'DJAgentClient.shared.attachDriverKitImage(' in caller
assert 'DJAgentClient.shared.detachDriverKitImage(' in caller
for source in (client, caller):
    assert not re.search(r'\b(import (DiskArbitration|IOKit)|DADiskUnmount|IOServiceOpen)\b', source)
bridge = read('DiskJockeyAgent/DJAgentOwnedImages.mm')
for binding in ('DJAgentConnections().attach(owner', 'DJAgentConnections().detach(owner',
                'DJAgentAuthorizeImage', 'DJAgentReadEndpointOpen', 'DJAgentReadEndpointCall',
                'DJAgentConnectionQueue()', 'DARegisterDiskAppearedCallback',
                'DASessionSetDispatchQueue', 'DJAgentConnections().appeared',
                'DADiskUnmount', 'DJAgentConnections().unmounted',
                'DJAgentRegistryIterateRecursively == kIORegistryIterateRecursively',
                'DJAgentRegistryIterateParents == kIORegistryIterateParents',
                '#include "DJAgentMediaIdentity.hpp"'):
    assert binding in bridge, binding + ' missing from platform bridge'
# The ancestry search the bridge includes walks every parent for the
# attachment identity, through the options the bridge checks against IOKit
# (#507).
identity = read('DiskJockeyAgent/DJAgentMediaIdentity.hpp')
assert 'DJAgentRegistryIterateRecursively | DJAgentRegistryIterateParents' in identity
assert 'kDJAttachmentIdentityKey' in identity, 'the ancestry search names no attachment identity'
assert 'DADiskCreateFromBSDName' not in bridge, 'never detach by a reused BSD name'
assert 'DADiskCopyIOMedia' in bridge
assert 'DJAgentOwnedImages.h' in read('DiskJockeyAgent/DiskJockeyAgent-Bridging-Header.h')
project = read('DiskJockey.xcodeproj/project.pbxproj')
phase = re.search(r'DA9E17A0000000000000000C /\* Sources \*/ = \{(.*?)\n\t\t\};', project, re.S).group(1)
assert 'DJAgentOwnedImages.mm in Sources' in phase
assert project.count('"-framework", DiskArbitration') >= 2
PY
then ok 'matching owned XPC methods, app callers, agent platform bridge and target wiring';
else fail 'owned DriverKit XPC route is incomplete'; fi
if [ "$fails" -eq 0 ]; then echo 'agent-owned-image-xpc: all checks passed'; fi
exit "$((fails > 0))"
