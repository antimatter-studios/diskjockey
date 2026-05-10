#!/bin/bash
# Build the standalone diskprobe binary and stage it under lib/diskprobe/.
#
# diskprobe is a CLI helper the host app shells out to during the
# attach-image flow: it opens a path (raw or qcow2/vhd/vhdx/vmdk
# container), walks any partition table inside, and emits a JSON
# description so the host can decide which partitions to mount and
# which fs module routes them.
#
# Output: $PROBE_OUT/diskprobe (single arm64+x86_64 universal binary).
#
# Environment:
#   SRCROOT       — project root (default: pwd)
#   PROBE_SRC     — path to the Rust source (default: $SRCROOT/vendor/rust-disk-probe)
#   PROBE_OUT     — output directory     (default: $SRCROOT/lib/diskprobe)

set -e

SRCROOT="${SRCROOT:-$(pwd)}"
SRCROOT="$(cd "${SRCROOT}" && pwd)"
PROBE_SRC="${PROBE_SRC:-${SRCROOT}/vendor/rust-disk-probe}"
PROBE_OUT="${PROBE_OUT:-${SRCROOT}/lib/diskprobe}"
case "$PROBE_SRC" in /*) ;; *) PROBE_SRC="${SRCROOT}/${PROBE_SRC}" ;; esac
case "$PROBE_OUT" in /*) ;; *) PROBE_OUT="${SRCROOT}/${PROBE_OUT}" ;; esac

mkdir -p "${PROBE_OUT}"

GREEN='\033[0;32m'
NC='\033[0m'

# Use the rustup toolchain (Cargo-level pin) — Homebrew cargo on PATH
# may shadow it.
export PATH="$HOME/.cargo/bin:$PATH"

cd "${PROBE_SRC}"

echo "Building diskprobe (arm64)..."
cargo build --release --target aarch64-apple-darwin

echo "Building diskprobe (x86_64)..."
cargo build --release --target x86_64-apple-darwin

echo "Creating universal binary..."
lipo -create \
    "${PROBE_SRC}/target/aarch64-apple-darwin/release/diskprobe" \
    "${PROBE_SRC}/target/x86_64-apple-darwin/release/diskprobe" \
    -output "${PROBE_OUT}/diskprobe"

chmod +x "${PROBE_OUT}/diskprobe"

echo -e "${GREEN}diskprobe build complete${NC}"
echo "  Binary:        ${PROBE_OUT}/diskprobe"
echo "  Architectures: $(lipo -info "${PROBE_OUT}/diskprobe" | cut -d: -f3)"
