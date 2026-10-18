#!/usr/bin/env bash
# The qcow2 reader's DriverKit boundary is measured, not assumed (#418).
# The measurement itself needs the DriverKit SDK and a nightly toolchain, so
# it lives in scripts/driverkit-reader-probe.sh; this guard holds the probe to
# a genuine DriverKit build and the recorded verdict to the probe's answer.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="$ROOT/scripts/driverkit-reader-probe.sh"
README="$ROOT/DiskJockeyVirtualDisk/README.md"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

if [ -x "$PROBE" ]; then
    ok 'the reader link probe exists and is executable'
else
    fail 'scripts/driverkit-reader-probe.sh is missing or not executable'
fi

probe_text="$(cat "$PROBE" 2>/dev/null)"
if grep -q 'arm64-apple-driverkit' <<<"$probe_text" \
   && grep -q -- '-Zbuild-std' <<<"$probe_text"; then
    ok 'the probe compiles the reader and std for the DriverKit platform'
else
    fail 'the probe must build the reader and std for an apple-driverkit LLVM target'
fi

if grep -q -E 'platform_version|vtool|no_platform_check|ld_classic' <<<"$probe_text"; then
    fail 'the probe retags or relaxes a platform check instead of building for DriverKit'
else
    ok 'the probe never retags a macOS object as DriverKit'
fi

if grep -q 'Undefined symbols' <<<"$probe_text" \
   && grep -q 'built for' <<<"$probe_text"; then
    ok 'the probe refuses unresolved symbols and platform-mismatch objects'
else
    fail 'the probe must fail on unresolved symbols and on a platform-mismatch object'
fi

stubs="$(find "$ROOT/DiskJockeyVirtualDisk" -type f \
    \( -iname '*stub*' -o -name '*.c' -o -name '*.cpp' -o -name '*.s' \) -print0 2>/dev/null \
    | xargs -0 grep -l -E '(^|[^A-Za-z0-9_])_?_tlv_(bootstrap|atexit)|DKRustStubs' 2>/dev/null)"
if [ -z "$stubs" ] && [ ! -e "$ROOT/DiskJockeyVirtualDisk/DKRustStubs.c" ]; then
    ok 'no replacement runtime or TLS stub is defined in the dext sources'
else
    fail "runtime stubs are defined in the dext sources: ${stubs:-DKRustStubs.c}"
fi

section="$(awk '/^## Reader boundary/{on=1; print; next} /^## /{on=0} on' "$README" 2>/dev/null)"
if [ -n "$section" ] \
   && grep -q 'agent-to-dext' <<<"$section" \
   && grep -q -E '[0-9]+ unresolved' <<<"$section" \
   && grep -q 'driverkit-reader-probe.sh' <<<"$section"; then
    ok 'the README records the verified boundary and the probe that measured it'
else
    fail 'DiskJockeyVirtualDisk/README.md must record the measured reader boundary'
fi

if [ "$fails" -eq 0 ]; then
    echo 'driverkit-reader-boundary: all checks passed'
fi
exit "$((fails > 0))"
