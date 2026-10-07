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
[ "$fails" -eq 0 ] || exit 1
echo 'xfs-block-device-bridge: all checks passed'
