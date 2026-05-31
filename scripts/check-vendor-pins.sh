#!/usr/bin/env bash
# check-vendor-pins.sh — validate that VENDOR_PINS.txt SHA column matches
# the current submodule gitlinks.
#
# Usage:
#   scripts/check-vendor-pins.sh [pins-file]
#
#   pins-file defaults to VENDOR_PINS.txt in the repo root.
#   Pass a temp file to validate a staged (not yet committed) version.
#
# Exit codes: 0 = OK, 1 = stale or missing pins
#
# Called by:
#   .githooks/pre-commit  — checks staged VENDOR_PINS.txt against staged submodule SHAs
#   scripts/ci.yml        — checks committed VENDOR_PINS.txt against checked-out SHAs

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PINS_FILE="${1:-VENDOR_PINS.txt}"

if [ ! -f "$PINS_FILE" ]; then
    echo "[pins-check] ERROR: $PINS_FILE not found — run 'make pins' to generate it"
    exit 1
fi

# SHA column from the pins file (path + sha, skip headers).
pins_shas=$(grep '^vendor/' "$PINS_FILE" | awk '{print $1, $2}' | sort)

# SHA column from the actual submodule index state.
# git submodule status reads the index, so it reflects staged gitlink updates
# (the + prefix means staged-but-different-from-HEAD; we strip all prefixes).
actual_shas=$(git submodule status | awk '{sha=$1; sub(/^[- +]/, "", sha); print $2, sha}' | sort)

if [ "$pins_shas" = "$actual_shas" ]; then
    echo "[pins-check] VENDOR_PINS.txt SHAs are up to date."
    exit 0
fi

echo "[pins-check] ERROR: VENDOR_PINS.txt is stale — run 'make pins' and commit the result"
echo ""
diff \
    <(echo "$actual_shas" | awk '{printf "  actual:    %-30s %s\n", $1, $2}') \
    <(echo "$pins_shas"   | awk '{printf "  pins-file: %-30s %s\n", $1, $2}') \
    || true
exit 1
