#!/usr/bin/env bash
# Image eject retains the mount's route and leaves privileged removal in XPC.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
if python3 - "$ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
def read(name): return (root / name).read_text()
service = read('DiskJockeyApplication/Services/FSKitMountService.swift')
view = read('DiskJockeyApplication/Views/AttachedDiskDetailView.swift')
def check(service, view):
    for binding in ('ImageEjectSequence()', 'imageEject.register(',
                    '.driverKit(owned.attachmentID)', '.hdiutil(hdiResult.parentDevice)',
                    'imageEject.eject(', 'DJAgentClient.shared.detachDriverKitImage(',
                    'Self.runHdiutilDetach('):
        assert binding in service, 'missing image eject binding: ' + binding
    assert service.count('imageEject.register(') >= 2, 'both image attach entry points must retain their route'
    assert 'FSKitMountService.shared.ejectImage(' in view, 'sidebar bypasses image eject'
    detach = service.split('func detach(name:', 1)[1].split('// MARK:', 1)[0]
    assert 'ejectImage(' in detach, 'menu bypasses image eject'
    assert not re.search(r'\b(IOServiceOpen|IOConnectCallMethod|DJAgentOwnedImageDetach)\b', service)
check(service, view)
for old in ('imageEject.register(', 'imageEject.eject(', 'DJAgentClient.shared.detachDriverKitImage('):
    try: check(service.replace(old, 'missing('), view)
    except AssertionError: pass
    else: raise AssertionError('guard accepts removed binding: ' + old)
bridge = read('DiskJockeyAgent/DJAgentOwnedImages.mm')
assert 'DADiskUnmount(disk, kDADiskUnmountOptionWhole' in bridge, 'owned detach must unmount every volume'
assert 'DJAgentConnections().unmounted(' in bridge, 'owned detach must await the unmount result'
PY
then ok 'mount identity reaches menu/sidebar eject and owned whole-volume unmount stays in the agent';
else fail 'image eject route is incomplete'; fi
if [ "$fails" -eq 0 ]; then echo 'image-eject-route: all checks passed'; fi
exit "$((fails > 0))"
