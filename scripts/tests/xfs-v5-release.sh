#!/usr/bin/env bash
# Contract tests for the release runner; these never impersonate an FSKit pass.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
if python3 "$ROOT/scripts/oracles/test_xfs_v5_release.py"; then
    ok 'release matrix and evidence contracts'
else
    fail 'release matrix and evidence contracts'
fi
[ "$fails" -eq 0 ] || exit 1
echo 'xfs-v5-release: all checks passed'
