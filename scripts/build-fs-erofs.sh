#!/bin/bash
# Build script for fs-erofs (vendored pure-Rust read-only EROFS driver)
# Called by both Xcode build phases and the Makefile.
#
# This script is SELF-HEALING:
# - Auto-initializes the submodule if missing
# - Checks the Rust toolchain is present
# - Compiles the arm64 static lib (Apple Silicon only)
#
# Output: $EROFS_OUT/libfs_erofs.a (arm64 .a) + include/fs_erofs.h.
# The Xcode DiskJockeyEROFS target links the .a via LIBRARY_SEARCH_PATHS
# + -lfs_erofs and #includes the header via its bridging header.
#
# Environment variables (optional, have defaults):
#   SRCROOT    - Project root (default: pwd)
#   EROFS_SRC  - Path to Rust source (default: $SRCROOT/vendor/rust-fs-erofs)
#   EROFS_OUT  - Path for build output (default: $SRCROOT/lib/fs_erofs)

set -e

SRCROOT="${SRCROOT:-$(pwd)}"
SRCROOT="$(cd "${SRCROOT}" && pwd)"
EROFS_SRC="${EROFS_SRC:-${SRCROOT}/vendor/rust-fs-erofs}"
EROFS_OUT="${EROFS_OUT:-${SRCROOT}/lib/fs_erofs}"
case "$EROFS_SRC" in /*) ;; *) EROFS_SRC="${SRCROOT}/${EROFS_SRC}" ;; esac
case "$EROFS_OUT" in /*) ;; *) EROFS_OUT="${SRCROOT}/${EROFS_OUT}" ;; esac
STAMP_FILE="${EROFS_OUT}/.build-stamp"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# =============================================================================
# Self-healing: Auto-initialize submodule
# =============================================================================

if [ ! -f "${EROFS_SRC}/Cargo.toml" ]; then
    echo "${YELLOW}fs-erofs submodule not found. Attempting to initialize...${NC}"
    if [ ! -d "${SRCROOT}/.git" ] && [ ! -f "${SRCROOT}/.git" ]; then
        echo "${RED}ERROR: Not a git repository. Cannot auto-initialize submodules.${NC}"
        echo "Clone with: git clone --recurse-submodules <repo-url>"
        exit 1
    fi
    if [ -f "${SRCROOT}/.gitmodules" ]; then
        echo "${YELLOW}Running: git submodule update --init vendor/rust-fs-erofs${NC}"
        cd "$SRCROOT"
        git submodule update --init vendor/rust-fs-erofs 2>/dev/null || \
            git submodule update --init --recursive 2>/dev/null || true
    fi
    if [ ! -f "${EROFS_SRC}/Cargo.toml" ]; then
        echo "${RED}ERROR: fs-erofs submodule could not be initialized.${NC}"
        echo "Manual fix: cd ${SRCROOT} && git submodule add https://github.com/antimatter-studios/rust-fs-erofs vendor/rust-fs-erofs"
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
    newest_source=$(find "${EROFS_SRC}/src" -name "*.rs" -newer "$STAMP_FILE" 2>/dev/null | head -1)
    if [ -n "$newest_source" ]; then echo "${YELLOW}fs-erofs: Source changed, rebuilding...${NC}"; return 0; fi
    if [ "${EROFS_SRC}/Cargo.toml" -nt "$STAMP_FILE" ]; then echo "${YELLOW}fs-erofs: Cargo.toml changed, rebuilding...${NC}"; return 0; fi
    if [ ! -f "${EROFS_OUT}/libfs_erofs.a" ]; then echo "${YELLOW}fs-erofs: static lib missing, rebuilding...${NC}"; return 0; fi
    return 1
}

if ! needs_rebuild; then
    emit_version_manifest "fs_erofs" "${EROFS_SRC}" "${EROFS_OUT}/VERSION.txt"
    echo "${GREEN}fs-erofs: Up to date${NC}"
    exit 0
fi

echo "${YELLOW}Building fs-erofs from ${EROFS_SRC}...${NC}"
cd "${EROFS_SRC}"

if ! rustup target list --installed 2>/dev/null | grep -q "^aarch64-apple-darwin$"; then
    echo "${YELLOW}Installing Rust target: aarch64-apple-darwin${NC}"
    rustup target add aarch64-apple-darwin
fi

echo "Building for arm64..."
cargo build --release --target aarch64-apple-darwin

mkdir -p "${EROFS_OUT}/include"
cp "${EROFS_SRC}/target/aarch64-apple-darwin/release/libfs_erofs.a" "${EROFS_OUT}/libfs_erofs.a"

# Copy fs_erofs.h alongside the static lib. fs_core.h comes from the sister
# fs-core crate (a transitive cargo dep, so its symbols ride into
# libfs_erofs.a). No qcow2/vhd headers — the read-only EROFS crate doesn't
# depend on the am-img-* container readers.
cp "${EROFS_SRC}/include/fs_erofs.h" "${EROFS_OUT}/include/fs_erofs.h"
FS_CORE_HDR="${SRCROOT}/vendor/rust-fs-core/include/fs_core.h"
[ -f "$FS_CORE_HDR" ] && cp "$FS_CORE_HDR" "${EROFS_OUT}/include/fs_core.h"

emit_version_manifest "fs_erofs" "${EROFS_SRC}" "${EROFS_OUT}/VERSION.txt"
touch "$STAMP_FILE"

echo "${GREEN}fs-erofs build complete${NC}"
echo "  Static lib:    ${EROFS_OUT}/libfs_erofs.a"
echo "  Architectures: $(lipo -info "${EROFS_OUT}/libfs_erofs.a" | cut -d: -f3)"
echo "  Manifest:      ${EROFS_OUT}/VERSION.txt"
