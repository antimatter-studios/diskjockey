#!/usr/bin/env bash
# guard: project-vendor-pins (diskjockey-local; ported from the original hook)
# If a vendor/ submodule gitlink is staged, require VENDOR_PINS.txt staged and
# consistent (scripts/check-vendor-pins.sh). Kept so github-guard's dispatcher
# doesn't drop diskjockey's only non-superseded check.
set -u
sub=$(git diff --cached --name-only --diff-filter=ACM | grep '^vendor/' || true)
[ -n "$sub" ] || exit 0
if ! git diff --cached --name-only | grep -qx 'VENDOR_PINS.txt'; then
  echo "project-vendor-pins: submodule(s) staged but VENDOR_PINS.txt is not — run 'make pins' and stage it." >&2
  exit 1
fi
if [ -x scripts/check-vendor-pins.sh ]; then
  p=$(mktemp); git show :VENDOR_PINS.txt > "$p"
  if ! scripts/check-vendor-pins.sh "$p"; then echo "project-vendor-pins: VENDOR_PINS.txt stale — run 'make pins'." >&2; rm -f "$p"; exit 1; fi
  rm -f "$p"
fi
exit 0
