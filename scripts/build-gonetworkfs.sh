#!/bin/sh
#
# build-gonetworkfs.sh — put the go-networkfs c-archives where the app links
# them.
#
# WHAT CHANGED, AND WHY THIS IS NOW SHORT
#
# This used to carry the build itself: 258 lines that knew Go's flags, the
# driver list, the c-archive invocation and its own stamp-file staleness
# scheme. All of that is knowledge about how to build go-networkfs, and it
# belongs to go-networkfs — which now states it, in its own chores.yml, as
# `chore archives` (build every driver plus the combined dispatcher) and
# `chore artifact` (say where they landed). The same contract every sibling
# Rust crate publishes.
#
# So this script no longer builds anything. It resolves the pinned tag and
# hands off to sibling-build.sh, which builds it in a throwaway worktree of
# that tag. When the driver list or a Go flag changes, it changes once, in
# go-networkfs, and every consumer follows.
#
# WHERE THE SOURCE COMES FROM
#
# A sibling checkout, not a vendored submodule. The submodule was a second
# copy of a repository already on disk — 146 MB of it — and a checkout shared
# with every other project that wants it is the point of the move. Override
# with NETWORKFS_SRC when it lives somewhere else.
#
# The checkout supplies git objects only. WHAT GETS COMPILED IS THE TAG NAMED
# IN SIBLING_PINS.txt, built in a worktree, so the developer's branch and
# working state cannot reach the app's binary.
set -e

SRCROOT="${SRCROOT:-$(pwd)}"
SRCROOT="$(cd "${SRCROOT}" && pwd)"

# Default to the sibling checkout beside this repository.
NETWORKFS_SRC="${NETWORKFS_SRC:-${SRCROOT}/../go-networkfs}"
NETWORKFS_OUT="${NETWORKFS_OUT:-${SRCROOT}/lib/go-networkfs}"
case "$NETWORKFS_SRC" in /*) ;; *) NETWORKFS_SRC="${SRCROOT}/${NETWORKFS_SRC}" ;; esac
case "$NETWORKFS_OUT" in /*) ;; *) NETWORKFS_OUT="${SRCROOT}/${NETWORKFS_OUT}" ;; esac

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ ! -f "${NETWORKFS_SRC}/go.mod" ]; then
    echo "${RED}ERROR: no go-networkfs at ${NETWORKFS_SRC}${NC}" >&2
    echo "" >&2
    echo "It is a sibling checkout now, not a submodule. Clone it beside this" >&2
    echo "repository, or point NETWORKFS_SRC at an existing one:" >&2
    echo "" >&2
    echo "  git clone https://github.com/antimatter-studios/go-networkfs $(dirname "${SRCROOT}")/go-networkfs" >&2
    echo "  make vendor-gonetworkfs NETWORKFS_SRC=/path/to/go-networkfs" >&2
    exit 1
fi

if ! command -v chore >/dev/null 2>&1; then
    echo "${RED}ERROR: chore is not installed, and it owns the build now.${NC}" >&2
    exit 1
fi

if [ ! -f "${NETWORKFS_SRC}/chores.yml" ]; then
    echo "${RED}ERROR: ${NETWORKFS_SRC} has no chores.yml${NC}" >&2
    echo "That checkout predates the chore migration; update it." >&2
    exit 1
fi

NETWORKFS_TAG="${NETWORKFS_TAG:-$(awk '$1=="go-networkfs"{print $2}' "${SRCROOT}/SIBLING_PINS.txt")}"
[ -n "$NETWORKFS_TAG" ] || { echo "${RED}ERROR: no go-networkfs pin in SIBLING_PINS.txt${NC}" >&2; exit 1; }

exec "${SRCROOT}/scripts/sibling-build.sh" \
    go-networkfs "$NETWORKFS_SRC" "$NETWORKFS_TAG" archives artifact "$NETWORKFS_OUT"
