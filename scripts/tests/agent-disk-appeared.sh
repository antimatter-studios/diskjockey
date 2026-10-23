#!/usr/bin/env bash
# The agent's DiskArbitration disk-appeared callback and its registry search,
# bound to the platform (#507, part of #457). The fixture drives the
# production connection registry through DJAgentDiskAppeared over a fake
# DiskArbitration and IOKit registry: a disk reaches an attachment only
# through DJAgentOwnedMediaDevice, never by its BSD name alone, and whatever
# the callback and the search copy is released exactly once. The text checks
# hold the platform source to those two injected seams.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/DiskJockeyAgent/DJAgentOwnedImages.mm"
SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

if "${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -pedantic \
    -I "$ROOT/DiskJockeyAgent" \
    "$ROOT/scripts/tests/fixtures/agent-disk-appeared.cpp" -o "$SANDBOX/appeared"; then
    if "$SANDBOX/appeared"; then
        ok 'a disk reaches an attachment only through the matcher, and every copy is released once'
    else
        fail 'the disk-appeared contract failed'
    fi
else
    fail 'the disk-appeared fixture does not build'
fi

has() { grep -qE -- "$1" "$SOURCE"; }
if has '#include "DJAgentDiskAppeared.hpp"' && has 'DJAgentDiskAppeared\(' \
    && ! has 'DJAgentMediaEvent[[:space:]]+[a-z]+[[:space:]]*\{'; then
    ok 'the platform callback builds its event only through DJAgentDiskAppeared'
else
    fail 'DJAgentOwnedImages.mm does not route its disk-appeared callback through DJAgentDiskAppeared'
fi
if has '#include "DJAgentMediaIdentity.hpp"' && has 'DJAgentRegistry[[:space:]]' \
    && has 'IORegistryEntrySearchCFProperty' && has 'CFNumberGetValue' \
    && has 'DJAgentMediaIdentity\(&'; then
    ok 'the registry search is bound to IORegistryEntrySearchCFProperty through DJAgentMediaIdentity'
else
    fail 'DJAgentOwnedImages.mm does not bind the injected registry search (#506) to IOKit'
fi
if has 'static_assert\(DJAgentRegistryIterateRecursively == kIORegistryIterateRecursively' \
    && has 'static_assert\(DJAgentRegistryIterateParents == kIORegistryIterateParents'; then
    ok 'the binding checks the spelled-out iteration options against IOKit'
else
    fail 'DJAgentOwnedImages.mm does not check the iteration options against IOKit'
fi

if [ "$fails" -eq 0 ]; then echo 'agent-disk-appeared: all checks passed'; fi
exit "$((fails > 0))"
