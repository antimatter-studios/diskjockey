#!/bin/bash
# Build script for fs-squashfs (vendored pure-Rust read-only SquashFS driver)
# Called by both Xcode build phases and the Makefile.
#
# This script is SELF-HEALING:
# - Auto-initializes the submodule if missing
# - Checks the Rust toolchain is present
# - Compiles the arm64 static lib (Apple Silicon only)
#
# Output: $SQUASHFS_OUT/libfs_squashfs.a (arm64 .a) + include/fs_squashfs.h.
# The Xcode DiskJockeySQUASHFS target links the .a via LIBRARY_SEARCH_PATHS
# + -lfs_squashfs and #includes the header via its bridging header.
#
# Environment variables (optional, have defaults):
#   SRCROOT       - Project root (default: pwd)
#   SQUASHFS_SRC  - Path to Rust source (default: $SRCROOT/vendor/rust-fs-squashfs)
#   SQUASHFS_OUT  - Path for build output (default: $SRCROOT/lib/fs_squashfs)

set -e

SRCROOT="${SRCROOT:-$(pwd)}"
SRCROOT="$(cd "${SRCROOT}" && pwd)"
SQUASHFS_SRC="${SQUASHFS_SRC:-${SRCROOT}/vendor/rust-fs-squashfs}"
SQUASHFS_OUT="${SQUASHFS_OUT:-${SRCROOT}/lib/fs_squashfs}"
case "$SQUASHFS_SRC" in /*) ;; *) SQUASHFS_SRC="${SRCROOT}/${SQUASHFS_SRC}" ;; esac
case "$SQUASHFS_OUT" in /*) ;; *) SQUASHFS_OUT="${SRCROOT}/${SQUASHFS_OUT}" ;; esac
STAMP_FILE="${SQUASHFS_OUT}/.build-stamp"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# =============================================================================
# Self-healing: Auto-initialize submodule
# =============================================================================

if [ ! -f "${SQUASHFS_SRC}/Cargo.toml" ]; then
    echo "${YELLOW}fs-squashfs submodule not found. Attempting to initialize...${NC}"
    if [ ! -d "${SRCROOT}/.git" ] && [ ! -f "${SRCROOT}/.git" ]; then
        echo "${RED}ERROR: Not a git repository. Cannot auto-initialize submodules.${NC}"
        echo "Clone with: git clone --recurse-submodules <repo-url>"
        exit 1
    fi
    if [ -f "${SRCROOT}/.gitmodules" ]; then
        echo "${YELLOW}Running: git submodule update --init vendor/rust-fs-squashfs${NC}"
        cd "$SRCROOT"
        git submodule update --init vendor/rust-fs-squashfs 2>/dev/null || \
            git submodule update --init --recursive 2>/dev/null || true
    fi
    if [ ! -f "${SQUASHFS_SRC}/Cargo.toml" ]; then
        echo "${RED}ERROR: fs-squashfs submodule could not be initialized.${NC}"
        echo "Manual fix: cd ${SRCROOT} && git submodule add https://github.com/antimatter-studios/rust-fs-squashfs vendor/rust-fs-squashfs"
        exit 1
    fi
    echo "${GREEN}✓ Submodule initialized${NC}"
fi

# =============================================================================
# Self-healing: Check Rust toolchain
# =============================================================================

if ! command -v cargo &> /dev/null; then
    echo "${RED}ERROR: Rust/Cargo is not installed.${NC}"
    echo "Install from: https://rustup.rs/"
    exit 1
fi
if ! command -v rustup &> /dev/null; then
    echo "${RED}ERROR: rustup is not installed (needed for cross-compilation).${NC}"
    exit 1
fi

# Emit VERSION.txt manifest describing the submodule commit that was built.
# Re-emitted on every run (even the skip path) so the manifest stays honest
# with no rebuild cost. Mirror of build-fs-ntfs.sh.
emit_version_manifest() {
    local lib_name="$1"
    local src_dir="$2"
    local out_file="$3"
    (
        cd "$src_dir"
        local source commit short_commit describe dirty ref ref_type commit_date
        source=$(git config --get remote.origin.url 2>/dev/null || echo "unknown")
        commit=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
        short_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        describe=$(git describe --always --long --dirty 2>/dev/null || echo "$short_commit")
        if [ -z "$(git status --porcelain 2>/dev/null)" ]; then dirty="false"; else dirty="true"; fi
        if tag=$(git describe --tags --exact-match 2>/dev/null); then
            ref="$tag"; ref_type="tag"
        elif branch=$(git symbolic-ref --short -q HEAD 2>/dev/null); then
            ref="$branch"; ref_type="branch"
        else
            ref="HEAD"; ref_type="detached"
        fi
        commit_date=$(git log -1 --format=%cI 2>/dev/null || echo "unknown")
        mkdir -p "$(dirname "$out_file")"
        {
            echo "lib=${lib_name}"
            echo "source=${source}"
            echo "ref=${ref}"
            echo "ref_type=${ref_type}"
            echo "commit=${commit}"
            echo "short_commit=${short_commit}"
            echo "describe=${describe}"
            echo "dirty=${dirty}"
            echo "commit_date=${commit_date}"
        } > "$out_file"
    )
}

needs_rebuild() {
    if [ ! -f "$STAMP_FILE" ]; then return 0; fi
    local newest_source
    newest_source=$(find "${SQUASHFS_SRC}/src" -name "*.rs" -newer "$STAMP_FILE" 2>/dev/null | head -1)
    if [ -n "$newest_source" ]; then echo "${YELLOW}fs-squashfs: Source changed, rebuilding...${NC}"; return 0; fi
    if [ "${SQUASHFS_SRC}/Cargo.toml" -nt "$STAMP_FILE" ]; then echo "${YELLOW}fs-squashfs: Cargo.toml changed, rebuilding...${NC}"; return 0; fi
    if [ ! -f "${SQUASHFS_OUT}/libfs_squashfs.a" ]; then echo "${YELLOW}fs-squashfs: static lib missing, rebuilding...${NC}"; return 0; fi
    return 1
}

if ! needs_rebuild; then
    emit_version_manifest "fs_squashfs" "${SQUASHFS_SRC}" "${SQUASHFS_OUT}/VERSION.txt"
    echo "${GREEN}fs-squashfs: Up to date${NC}"
    exit 0
fi

echo "${YELLOW}Building fs-squashfs from ${SQUASHFS_SRC}...${NC}"
cd "${SQUASHFS_SRC}"

if ! rustup target list --installed 2>/dev/null | grep -q "^aarch64-apple-darwin$"; then
    echo "${YELLOW}Installing Rust target: aarch64-apple-darwin${NC}"
    rustup target add aarch64-apple-darwin
fi

echo "Building for arm64..."
cargo build --release --target aarch64-apple-darwin

mkdir -p "${SQUASHFS_OUT}/include"
cp "${SQUASHFS_SRC}/target/aarch64-apple-darwin/release/libfs_squashfs.a" "${SQUASHFS_OUT}/libfs_squashfs.a"

# Copy fs_squashfs.h alongside the static lib. fs_core.h comes from the
# sister fs-core crate (a transitive cargo dep, so its symbols ride into
# libfs_squashfs.a). No qcow2/vhd headers — the read-only SquashFS crate
# doesn't depend on the am-img-* container readers.
cp "${SQUASHFS_SRC}/include/fs_squashfs.h" "${SQUASHFS_OUT}/include/fs_squashfs.h"
FS_CORE_HDR="${SRCROOT}/vendor/rust-fs-core/include/fs_core.h"
[ -f "$FS_CORE_HDR" ] && cp "$FS_CORE_HDR" "${SQUASHFS_OUT}/include/fs_core.h"

emit_version_manifest "fs_squashfs" "${SQUASHFS_SRC}" "${SQUASHFS_OUT}/VERSION.txt"
touch "$STAMP_FILE"

echo "${GREEN}fs-squashfs build complete${NC}"
echo "  Static lib:    ${SQUASHFS_OUT}/libfs_squashfs.a"
echo "  Architectures: $(lipo -info "${SQUASHFS_OUT}/libfs_squashfs.a" | cut -d: -f3)"
echo "  Manifest:      ${SQUASHFS_OUT}/VERSION.txt"
