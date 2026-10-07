#!/usr/bin/env bash
# The extension must ship the callbacks exercised by the host-free/native tests.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
check() {
    if python3 - "$@" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
assert sys.argv[2] in source
PY
    then ok "$3"; else fail "$3"; fi
}
check Package.swift '"XfsBlockDeviceContext.swift"' 'host-free suite compiles production callback context'
check DiskJockeyXFS/XfsFileSystem.swift 'XfsBlockDeviceBridge.makeHandle(contextPtr: contextPtr, logger: dlog)' 'mount uses production native bridge'
check DiskJockeyXFS/XfsBlockDeviceBridge.swift 'coreCfg.read = XfsBlockDeviceContext.readCallback' 'native read uses tested callback'
check DiskJockeyXFS/XfsBlockDeviceBridge.swift 'coreCfg.write = context.isWritable ? XfsBlockDeviceContext.writeCallback : nil' 'native writes respect resource capability'
check DiskJockeyXFS/XfsBlockDeviceBridge.swift 'coreCfg.flush = XfsBlockDeviceContext.flushCallback' 'native flush uses tested callback'
check DiskJockeyXFS/XfsBlockDeviceBridge.swift 'coreCfg.size = context.sizeBytes' 'native device advertises bounded slice size'
check DiskJockeyXFS/XfsVolume.swift 'Unmanaged<XfsBlockDeviceContext>.fromOpaque(ctx).release()' 'volume releases correct callback context'
if python3 - "$ROOT/DiskJockey.xcodeproj/project.pbxproj" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
target = re.search(r'/\* DiskJockeyXFS \*/ = \{\s*isa = PBXNativeTarget;(.*?)\n\s*name = DiskJockeyXFS;', text, re.S)
assert target, 'XFS extension target is absent'
phases = re.search(r'buildPhases = \((.*?)\);', target[1], re.S)
assert phases, 'XFS target has no build phases'
paths = set()
for phase in re.findall(r'([0-9A-F]{24}) /\*', phases[1]):
    body = re.search(r'^\s*' + re.escape(phase) + r' /\*[^\n]*\*/ = \{\s*isa = PBXSourcesBuildPhase;(.*?)\n\s*\};', text, re.S | re.M)
    if not body:
        continue
    for build in re.findall(r'([0-9A-F]{24}) /\*', body[1]):
        entry = re.search(r'^\s*' + re.escape(build) + r' /\*[^\n]*\*/ = \{isa = PBXBuildFile; fileRef = ([0-9A-F]{24})', text, re.M)
        assert entry, 'XFS source build entry is absent'
        reference = re.search(r'^\s*' + re.escape(entry[1]) + r' /\*[^\n]*\*/ = \{isa = PBXFileReference;[^\n]*?path = ([^;]+);', text, re.M)
        assert reference, 'XFS source file reference is absent'
        paths.add(reference[1].strip('"'))
assert 'XfsMountPolicy.swift' in paths, 'mount policy is not compiled into the shipped XFS extension'
PY
then ok 'shipped XFS target compiles the mount policy'; else fail 'shipped XFS target omits mount policy'; fi
[ "$fails" -eq 0 ] || exit 1
echo 'xfs-block-device-bridge: all checks passed'
