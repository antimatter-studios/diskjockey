#!/usr/bin/env bash
#
# probe-tool-name.sh — the probe is staged, found and named as `blk.probe`
# (diskjockey#236).
#
# The tool from rust-blk-probe is `blk.probe` everywhere, by owner decision,
# so there is one name for it. The app finds it by path rather than on PATH,
# so a stale name builds cleanly and fails at run time with "binary not
# found". Three things have to agree and nothing else checks them:
#
#   1. scripts/build-blk.probe.sh stages lib/blk.probe/blk.probe from the
#      release tarball's bin/blk.probe. scripts/tests/probe-is-pinned.sh runs
#      it, against a stub `gh`, and checks the staged tree exactly (#239).
#   2. Both Swift call sites look for that path, and for `blk.probe` in the
#      bundle's Resources.
#   3. No tracked file spells the tool `blk-probe`. The repository is still
#      `rust-blk-probe`, and dated reports record what things were called
#      when they were written; those are the exceptions, with
#      docs/constellation/naming-discussion.md, which discusses `blk-probe`
#      as a crates.io package name rather than as the tool.
#
#   bash scripts/tests/probe-tool-name.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF="scripts/tests/$(basename "${BASH_SOURCE[0]}")"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# --- 2. The Swift call sites look for blk.probe. --------------------------
agent="$REPO/DiskJockeyAgent/AgentImpl.swift"
mount="$REPO/DiskJockeyApplication/Services/FSKitMountService.swift"
grep -qF '"Resources/blk.probe"' "$agent" && ok "the agent looks in Resources/blk.probe" \
    || fail "DiskJockeyAgent/AgentImpl.swift does not look for Resources/blk.probe"
grep -qF '"lib/blk.probe/blk.probe"' "$agent" && ok "the agent's dev fallback is lib/blk.probe/blk.probe" \
    || fail "DiskJockeyAgent/AgentImpl.swift does not fall back to lib/blk.probe/blk.probe"
grep -qF 'forResource: "blk.probe"' "$mount" && ok "the app looks for the blk.probe resource" \
    || fail "FSKitMountService.swift does not look for the blk.probe resource"
grep -qF '"lib/blk.probe/blk.probe"' "$mount" && ok "the app's dev fallback is lib/blk.probe/blk.probe" \
    || fail "FSKitMountService.swift does not fall back to lib/blk.probe/blk.probe"

# --- 3. Nothing spells the tool blk-probe. --------------------------------
# `rust-blk-probe` is the repository and is fine. The two dated reports are
# records of 2026-08-30 and are not rewritten.
hits="$(git -C "$REPO" grep -nF 'blk-probe' -- . \
    ":(exclude)$SELF" \
    ':(exclude)docs/constellation-report-2026-08-30.md' \
    ':(exclude)docs/constellation/evidence-2026-08-30.md' \
    ':(exclude)docs/constellation/naming-discussion.md' |
    sed 's/rust-blk-probe//g' | grep -F 'blk-probe' || true)"
if [ -z "$hits" ]; then
    ok "no tracked file names the tool blk-probe"
else
    fail "these still name the tool blk-probe:"$'\n'"$hits"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo 'probe-tool-name: all checks passed'
else
    echo "probe-tool-name: $fails check(s) failed" >&2
fi
exit "$((fails > 0))"
