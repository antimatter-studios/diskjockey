#!/bin/bash
# Build the standalone blk.probe binary and stage it under lib/blk.probe/.
#
# blk.probe is a CLI helper the host app shells out to during the
# attach-image flow: it opens a path (raw or qcow2/vhd/vhdx/vmdk
# container), walks any partition table inside, and emits a JSON
# description so the host can decide which partitions to mount and
# which fs module routes them.
#
# THE CARGO TARGET IS blk_probe, AND THIS RENAMES IT. Cargo refuses a dot
# in a target name, so the sibling's [[bin]] is `blk_probe`; the tool the
# app looks for is `blk.probe`. `--bin blk_probe` makes a sibling checkout
# that predates the rename fail here, by name, rather than stage nothing.
# scripts/tests/probe-tool-name.sh runs this against stub cargo and lipo.
#
# Output: $PROBE_OUT/blk.probe (single arm64+x86_64 universal binary).
#
# Environment:
#   SRCROOT       — project root (default: pwd)
#   PROBE_SRC     — path to the Rust source (default: $SRCROOT/../rust-blk-probe)
#   PROBE_OUT     — output directory     (default: $SRCROOT/lib/blk.probe)

set -e

TARGET=blk_probe
TOOL=blk.probe

SRCROOT="${SRCROOT:-$(pwd)}"
SRCROOT="$(cd "${SRCROOT}" && pwd)"
PROBE_SRC="${PROBE_SRC:-${SRCROOT}/../rust-blk-probe}"
PROBE_OUT="${PROBE_OUT:-${SRCROOT}/lib/${TOOL}}"
case "$PROBE_SRC" in /*) ;; *) PROBE_SRC="${SRCROOT}/${PROBE_SRC}" ;; esac
case "$PROBE_OUT" in /*) ;; *) PROBE_OUT="${SRCROOT}/${PROBE_OUT}" ;; esac

mkdir -p "${PROBE_OUT}"

GREEN='\033[0;32m'
NC='\033[0m'

# Use the rustup toolchain (Cargo-level pin) — Homebrew cargo on PATH
# may shadow it.
export PATH="$HOME/.cargo/bin:$PATH"

cd "${PROBE_SRC}"

echo "Building ${TOOL} (arm64)..."
cargo build --release --target aarch64-apple-darwin --bin "${TARGET}"

echo "Building ${TOOL} (x86_64)..."
cargo build --release --target x86_64-apple-darwin --bin "${TARGET}"

echo "Creating universal binary..."
lipo -create \
    "${PROBE_SRC}/target/aarch64-apple-darwin/release/${TARGET}" \
    "${PROBE_SRC}/target/x86_64-apple-darwin/release/${TARGET}" \
    -output "${PROBE_OUT}/${TOOL}"

chmod +x "${PROBE_OUT}/${TOOL}"

echo -e "${GREEN}${TOOL} build complete${NC}"
echo "  Binary:        ${PROBE_OUT}/${TOOL}"
echo "  Architectures: $(lipo -info "${PROBE_OUT}/${TOOL}" | cut -d: -f3)"
