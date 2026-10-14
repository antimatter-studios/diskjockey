#!/usr/bin/env bash
# The production XFS volume over the vendored bundle, driven through FSKit's
# volume methods against a Linux-made image (diskjockey#322, #355).
#
#   scripts/test-xfs-mutations.sh <image> <expected-dir>
#
# The image comes from `scripts/xfs-mutations-vm.sh create`, which runs
# scripts/oracles/xfs-mutations-linux.sh in fs-linux-test-harness's VM, and
# goes back there for `verify`: xfs_repair -n, xfs_db, xfs_logprint and the
# guest's kernel check what this wrote, against the files left in
# <expected-dir>. The XFS mutations workflow runs all three steps on every
# pull request that changes DiskJockeyXFS/.
#
# It needs the XFS bundle (scripts/build-bundles.sh xfs) and Xcode's
# toolchain, and no app build: DiskJockeyLibrary is compiled here from its
# own sources, every Swift file under DiskJockeyLibrary/ in Swift 5 mode, as
# Package.swift compiles it for the library tier. No fskitd is involved and
# nothing is launched, so it runs on a CI runner with no GUI session.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [ "${1:-}" != --run-oracle ]; then
    [ $# -eq 2 ] || { echo 'usage: scripts/test-xfs-mutations.sh <image> <expected-dir>' >&2; exit 2; }
    exec scripts/quiet-run.sh xfs-mutations 100 15000 -- bash "$0" --run-oracle "$1" "$2"
fi
image="$2"
expected="$3"
[ -f "$image" ] || { echo 'FAIL: make the image with scripts/oracles/xfs-mutations-linux.sh create first' >&2; exit 1; }
[ -d "$expected" ] || { echo "FAIL: $expected is not a directory" >&2; exit 1; }
if [ ! -f lib/bundle_xfs/libdj_xfs_bundle.a ] || [ ! -f lib/bundle_xfs/include/fs_xfs.h ]; then
    echo 'FAIL: run scripts/build-bundles.sh xfs (or make vendor-bundles) to provide the XFS bundle and headers' >&2
    exit 1
fi
out=tmp/xfs-oracle
target=arm64-apple-macos15.5
rm -rf "$out/library"
mkdir -p "$out/library"

library_sources=()
while IFS= read -r -d '' source; do library_sources+=("$source"); done \
    < <(find DiskJockeyLibrary -name '*.swift' -print0 | sort -z)
[ "${#library_sources[@]}" -gt 0 ] || { echo 'FAIL: no Swift sources under DiskJockeyLibrary/' >&2; exit 1; }
xcrun swiftc -swift-version 5 -target "$target" -parse-as-library -wmo \
    -module-name DiskJockeyLibrary -emit-library -static \
    -emit-module -emit-module-path "$out/library/DiskJockeyLibrary.swiftmodule" \
    -o "$out/library/libDiskJockeyLibrary.a" "${library_sources[@]}"

# The extension's sources the volume needs, less XfsFileSystem.swift, whose
# loadResource the oracle's mount() repeats call for call.
xcrun swiftc -swift-version 5 -target "$target" -parse-as-library \
    -I "$out/library" -L "$out/library" -lDiskJockeyLibrary -framework FSKit \
    -I lib/bundle_xfs/include -import-objc-header DiskJockeyXFS/DiskJockeyXFS-Bridging-Header.h \
    DiskJockeyXFS/XfsVolume.swift DiskJockeyXFS/XfsDriver.swift DiskJockeyXFS/XfsMountPolicy.swift \
    DiskJockeyXFS/XfsBlockDeviceContext.swift DiskJockeyXFS/XfsBlockDeviceBridge.swift \
    DiskJockeyXFS/XfsCheck.swift DiskJockeyXFS/XfsLog.swift \
    scripts/oracles/xfs-mutations.swift lib/bundle_xfs/libdj_xfs_bundle.a \
    -o "$out/xfs-mutations"
"$out/xfs-mutations" "$image" "$expected"
