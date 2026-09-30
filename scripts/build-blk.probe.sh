#!/bin/bash
# Stage the blk.probe binary under lib/blk.probe/, from the attested release
# of the rust-blk-probe tag SIBLING_PINS.txt names.
#
# blk.probe is a CLI helper the host app shells out to during the
# attach-image flow: it opens a path (raw or qcow2/vhd/vhdx/vmdk
# container), walks any partition table inside, and emits a JSON
# description so the host can decide which partitions to mount and
# which fs module routes them.
#
# IT IS DOWNLOADED, NOT BUILT (#239). This script used to build whatever
# ../rust-blk-probe had checked out -- any branch, any uncommitted change --
# for the one binary that parses untrusted images before anything is
# mounted. scripts/sibling-build.sh cannot pin it either: its `artifact` is a
# file rather than a directory, and its six parser crates (am-fs-core, the
# am-img-* readers, am-partitions) are `path = "../rust-*"` dependencies, so
# pinning the probe's tag alone would still compile whatever those six
# checkouts held.
#
# The release tarball has none of those problems. rust-blk-probe's
# release.yml builds it against the sibling refs its own CI pins, and signs a
# build-provenance attestation for it. So this script:
#
#   1. reads `rust-blk-probe <tag>` from SIBLING_PINS.txt;
#   2. downloads rust-blk-probe-<version>-darwin-arm64.tar.gz and its .sha256
#      from that tag's GitHub release (the app is ARCHS = arm64 only);
#   3. checks the sha256, then that the attestation was signed by
#      rust-blk-probe's release workflow, and refuses on either failure;
#   4. stages bin/blk.probe as lib/blk.probe/blk.probe, beside
#      VERSION-rust-blk-probe.txt recording the tag, the tarball and its sha256.
#
# Nothing is staged until every check has passed. Needs `gh` (2.49 or later,
# for `gh attestation`). scripts/tests/probe-is-pinned.sh runs this against a
# stub `gh`.
#
# Output: $PROBE_OUT/blk.probe and $PROBE_OUT/VERSION-rust-blk-probe.txt
#
# Environment:
#   SRCROOT       — project root (default: pwd)
#   PROBE_OUT     — output directory (default: $SRCROOT/lib/blk.probe)

set -euo pipefail

TOOL=blk.probe
REPO=antimatter-studios/rust-blk-probe
SIGNER="${REPO}/.github/workflows/release.yml"
PLATFORM=darwin-arm64

SRCROOT="${SRCROOT:-$(pwd)}"
SRCROOT="$(cd "${SRCROOT}" && pwd)"
PROBE_OUT="${PROBE_OUT:-${SRCROOT}/lib/${TOOL}}"
case "$PROBE_OUT" in /*) ;; *) PROBE_OUT="${SRCROOT}/${PROBE_OUT}" ;; esac

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
die() { printf "%bERROR: %s%b\n" "$RED" "$1" "$NC" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh is not installed; it downloads the release and verifies its attestation"

TAG="$(awk '$1=="rust-blk-probe"{print $2}' "${SRCROOT}/SIBLING_PINS.txt" 2>/dev/null || true)"
[ -n "$TAG" ] || die "SIBLING_PINS.txt names no rust-blk-probe tag, so there is no release to stage"
VERSION="${TAG#v}"
ASSET="rust-blk-probe-${VERSION}-${PLATFORM}.tar.gz"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dj-blk.probe-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading ${ASSET} from ${REPO} ${TAG}..."
gh release download "$TAG" --repo "$REPO" --pattern "$ASSET" --pattern "$ASSET.sha256" --dir "$WORK" \
    || die "could not download ${ASSET} from the ${TAG} release of ${REPO}"
[ -f "$WORK/$ASSET" ] || die "the ${TAG} release of ${REPO} has no ${ASSET}"
[ -f "$WORK/$ASSET.sha256" ] || die "the ${TAG} release of ${REPO} has no ${ASSET}.sha256"

if command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$WORK/$ASSET" | cut -d' ' -f1)"
else
    actual="$(sha256sum "$WORK/$ASSET" | cut -d' ' -f1)"
fi
expected="$(awk '{print $1; exit}' "$WORK/$ASSET.sha256")"
[ "$actual" = "$expected" ] \
    || die "${ASSET} is sha256 ${actual}, but its .sha256 says ${expected:-nothing}"

echo "Verifying the build-provenance attestation..."
gh attestation verify "$WORK/$ASSET" --repo "$REPO" --signer-workflow "$SIGNER" >/dev/null \
    || die "${ASSET} has no attestation signed by ${SIGNER}; refusing to stage it"

mkdir -p "$WORK/x"
tar -xzf "$WORK/$ASSET" -C "$WORK/x"
[ -f "$WORK/x/bin/${TOOL}" ] || die "${ASSET} has no bin/${TOOL}"

rm -rf "${PROBE_OUT}"
mkdir -p "${PROBE_OUT}"
cp "$WORK/x/bin/${TOOL}" "${PROBE_OUT}/${TOOL}"
chmod +x "${PROBE_OUT}/${TOOL}"
{
    echo "rust-blk-probe ${TAG}"
    echo "tarball ${ASSET}"
    echo "sha256 ${actual}"
    echo "attestation verified: signer ${SIGNER}"
} > "${PROBE_OUT}/VERSION-rust-blk-probe.txt"

echo -e "${GREEN}${TOOL} ${TAG} staged${NC}"
echo "  Binary:  ${PROBE_OUT}/${TOOL}"
echo "  sha256:  ${actual} (${ASSET})"
