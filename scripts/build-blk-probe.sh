#!/bin/bash
# Build the standalone blk-probe binary and stage it under lib/blk-probe/.
#
# blk-probe is a CLI helper the host app shells out to during the
# attach-image flow: it opens a path (raw or qcow2/vhd/vhdx/vmdk
# container), walks any partition table inside, and emits a JSON
# description so the host can decide which partitions to mount and
# which fs module routes them.
#
# Output: $PROBE_OUT/blk-probe (single arm64+x86_64 universal binary).
#
# Environment:
#   SRCROOT       — project root (default: pwd)
#   PROBE_SRC     — path to the Rust source (default: $SRCROOT/../rust-blk-probe)
#   PROBE_OUT     — output directory     (default: $SRCROOT/lib/blk-probe)

set -e

SRCROOT="${SRCROOT:-$(pwd)}"
SRCROOT="$(cd "${SRCROOT}" && pwd)"
PROBE_SRC="${PROBE_SRC:-${SRCROOT}/../rust-blk-probe}"
PROBE_OUT="${PROBE_OUT:-${SRCROOT}/lib/blk-probe}"
case "$PROBE_SRC" in /*) ;; *) PROBE_SRC="${SRCROOT}/${PROBE_SRC}" ;; esac
case "$PROBE_OUT" in /*) ;; *) PROBE_OUT="${SRCROOT}/${PROBE_OUT}" ;; esac

mkdir -p "${PROBE_OUT}"

GREEN='\033[0;32m'
NC='\033[0m'

# Use the rustup toolchain (Cargo-level pin) — Homebrew cargo on PATH
# may shadow it.
export PATH="$HOME/.cargo/bin:$PATH"

cd "${PROBE_SRC}"

echo "Building blk-probe (arm64)..."
cargo build --release --target aarch64-apple-darwin

echo "Building blk-probe (x86_64)..."
cargo build --release --target x86_64-apple-darwin

echo "Creating universal binary..."
lipo -create \
    "${PROBE_SRC}/target/aarch64-apple-darwin/release/blk-probe" \
    "${PROBE_SRC}/target/x86_64-apple-darwin/release/blk-probe" \
    -output "${PROBE_OUT}/blk-probe"

chmod +x "${PROBE_OUT}/blk-probe"

echo -e "${GREEN}blk-probe build complete${NC}"
echo "  Binary:        ${PROBE_OUT}/blk-probe"
echo "  Architectures: $(lipo -info "${PROBE_OUT}/blk-probe" | cut -d: -f3)"
