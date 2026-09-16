#!/usr/bin/env bash
#
# am-ledger-start.sh — a project cannot give two repositories one name
# (diskjockey#130).
#
# `start` keyed each repository by the last segment of owner/name and never
# checked for a collision, and every later command looks a short name up
# and takes the first match. So `christhomas/rust-fs-ext4` beside
# `antimatter-studios/rust-fs-ext4` (the pending org move) filed both
# repositories' issues into one row space, silently.
#
# Projects live under a scratch HOME; the real state directory is never
# touched. Only explicit owner/name arguments are driven: `--org` needs
# the network, and both branches feed the same `pairs` array.
#
#   bash scripts/tests/am-ledger-start.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LEDGER_BIN="$REPO/scripts/am-ledger"
fails=0
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
export HOME="$sandbox/home"; mkdir -p "$HOME"
unset AM_LEDGER_PROJECT AM_LEDGER_DIR

ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
proj() { printf '%s' "$HOME/.local/state/am-ledger/$1"; }

echo "am-ledger-start: short names are unique within a project"

# ACCEPTANCE: distinct short names create the project.
"$LEDGER_BIN" start fine antimatter-studios/rust-fs-xfs christhomas/rust-fs-ext4 >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && [ -f "$(proj fine)/repos.tsv" ]; then ok "distinct short names create the project"
else fail "a valid project was not created (rc=$rc)"; fi

# THE DEFECT: two owners, one repository name.
err=$("$LEDGER_BIN" start collide christhomas/rust-fs-ext4 antimatter-studios/rust-fs-ext4 2>&1 >/dev/null); rc=$?
if [ "$rc" != 0 ]; then ok "two repositories with one short name are refused (rc=$rc)"
else fail "two repositories with one short name were accepted"; fi
case "$err" in
    *christhomas/rust-fs-ext4*antimatter-studios/rust-fs-ext4*|*antimatter-studios/rust-fs-ext4*christhomas/rust-fs-ext4*)
        ok "the refusal names both slugs" ;;
    *) fail "the refusal does not name both slugs: $err" ;;
esac
if [ -e "$(proj collide)" ]; then fail "a refused start left a half-made project at $(proj collide)"
else ok "a refused start leaves no project directory behind"; fi

# THE SAME CLEANUP for the other refusal on that path, which returned
# without removing the directory it had just created.
"$LEDGER_BIN" start notaslug rust-fs-ext4 >/dev/null 2>&1; rc=$?
if [ "$rc" != 0 ] && [ ! -e "$(proj notaslug)" ]; then ok "a non owner/name argument is refused and leaves no directory"
else fail "a non owner/name argument: rc=$rc, directory present: $([ -e "$(proj notaslug)" ] && echo yes || echo no)"; fi

echo
if [ "$fails" = 0 ]; then
    echo "am-ledger-start: all checks passed"
else
    echo "am-ledger-start: $fails check(s) failed" >&2
fi
exit "$fails"
