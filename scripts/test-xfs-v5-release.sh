#!/usr/bin/env bash
# Dedicated macOS release job, deliberately outside the unsigned PR tiers.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/scripts/quiet-run.sh" xfs-v5-release 100 20000 -- \
    python3 "$ROOT/scripts/xfs-v5-release.py" "$@"
