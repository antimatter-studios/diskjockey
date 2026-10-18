#!/usr/bin/env bash
# Apple's SDK/linker checks the complete lifecycle without runtime replacements.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${1:-$ROOT/tmp/driverkit-pending-build}"
mkdir -p "$WORK"
SDK="$(xcrun --sdk driverkit --show-sdk-path)"
VERSION="$(xcrun --sdk driverkit --show-sdk-version)"
cat > "$WORK/probe.cpp" <<'CPP'
#include "DJVirtualDiskUserClientDispatch.h"
using Pending = DJPendingReads<>;
using Dispatch = DJUserClientDispatch<>;
// Externally supplied hooks force all paths to link; this is never executed.
extern "C" void probe(DJReadIdentities &ids, Pending::Hooks hooks,
                       const DJMountGeometry &geometry, Pending::Completion done,
                       const void *header, const void *payload) {
    Pending pending(ids, hooks);
    pending.connect();
    pending.submit(geometry, 1, 0, 512, 1000, done, nullptr);
    pending.reply(header, sizeof(DJReadReply), payload, 512);
    pending.pendingCount();
    pending.disconnect();
}
extern "C" void probeDispatch(DJReadIdentities &ids, Dispatch::Platform platform,
                               const DJMountGeometry &geometry, Pending::Completion done,
                               const DJDispatchArguments &arguments) {
    Dispatch dispatch(ids, platform);
    dispatch.externalMethod(kDJSelectorConnectReadEndpoint, arguments);
    dispatch.submit(geometry, 1, 0, 512, 1000, done, nullptr);
    dispatch.externalMethod(kDJSelectorDeliverReadReply, arguments);
    dispatch.externalMethod(kDJSelectorDisconnectReadEndpoint, arguments);
    dispatch.pendingCount();
    uint64_t size = 0;
    dispatch.virtualSize(1, &size);
    dispatch.stop();
}
int main() { return 0; }
CPP
xcrun --sdk driverkit clang++ -target "arm64-apple-driverkit$VERSION" -isysroot "$SDK" \
    -std=c++17 -Wall -Wextra -Werror -pedantic -fno-exceptions -fno-rtti \
    -I "$ROOT/DiskJockeyVirtualDisk" \
    -F"$SDK/System/DriverKit/System/Library/Frameworks" -framework DriverKit \
    -L"$SDK/System/DriverKit/usr/lib" -Wl,-fatal_warnings \
    "$WORK/probe.cpp" -o "$WORK/probe"
printf 'driverkit-pending-build: lifecycle and user-client dispatch link against DriverKit %s\n' "$VERSION"
