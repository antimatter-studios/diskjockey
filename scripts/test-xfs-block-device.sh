#!/usr/bin/env bash
# Native callback oracle, after make vendor-all and scripts/test-app.sh.
# DJ_FRAMEWORK_DIR optionally overrides Xcode's Debug products directory.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [ "${1:-}" != --run-oracle ]; then
    exec scripts/quiet-run.sh xfs-block-device 100 15000 -- bash "$0" --run-oracle
fi
frameworks="${DJ_FRAMEWORK_DIR:-}"
if [ -z "$frameworks" ]; then
    frameworks="$(xcodebuild -project DiskJockey.xcodeproj -scheme DiskJockey \
        -destination 'platform=macOS,arch=arm64' -configuration Debug -showBuildSettings -json | \
        jq -er '.[] | select(.target == "DiskJockey") | .buildSettings.BUILT_PRODUCTS_DIR')"
fi
if [ ! -d "$frameworks/DiskJockeyLibrary.framework" ]; then
    echo 'FAIL: run scripts/test-app.sh to build DiskJockeyLibrary (or set DJ_FRAMEWORK_DIR)' >&2
    exit 1
fi
if [ ! -f lib/bundle_xfs/include/fs_core.h ] || [ ! -f lib/bundle_xfs/libdj_xfs_bundle.a ]; then
    echo 'FAIL: run make vendor-bundles to provide the published XFS bundle and headers' >&2
    exit 1
fi
mkdir -p tmp/xfs-oracle
xcrun swiftc -warnings-as-errors -swift-version 5 -target arm64-apple-macos15.5 \
    -F "$frameworks" -framework DiskJockeyLibrary \
    -Xlinker -rpath -Xlinker "$frameworks" \
    -import-objc-header lib/bundle_xfs/include/fs_core.h \
    DiskJockeyXFS/XfsBlockDeviceContext.swift \
    DiskJockeyXFS/XfsBlockDeviceBridge.swift \
    scripts/oracles/xfs-block-device.swift \
    lib/bundle_xfs/libdj_xfs_bundle.a \
    -o tmp/xfs-oracle/xfs-block-device
tmp/xfs-oracle/xfs-block-device
