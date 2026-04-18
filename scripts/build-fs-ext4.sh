#!/bin/bash
# Build script for fs-ext4 (vendored pure-Rust ext4 filesystem driver)
# Called by both Xcode build phases and Makefile
#
# This script is SELF-HEALING:
# - Auto-initializes submodules if missing
# - Auto-installs Rust toolchain if needed
# - Compiles universal binary (arm64 + x86_64)
# - Creates XCFramework for Xcode linking
#
# Environment variables (optional, have defaults):
#   SRCROOT    - Project root (default: pwd)
#   EXT4_SRC   - Path to Rust source (default: $SRCROOT/vendor/rust-fs-ext4)
#   EXT4_OUT   - Path for build output (default: $SRCROOT/vendor/fs_ext4)

set -e

# Configuration with defaults
SRCROOT="${SRCROOT:-$(pwd)}"
SRCROOT="$(cd "${SRCROOT}" && pwd)"
EXT4_SRC="${EXT4_SRC:-${SRCROOT}/vendor/rust-fs-ext4}"
EXT4_OUT="${EXT4_OUT:-${SRCROOT}/vendor/fs_ext4}"
case "$EXT4_SRC" in /*) ;; *) EXT4_SRC="${SRCROOT}/${EXT4_SRC}" ;; esac
case "$EXT4_OUT" in /*) ;; *) EXT4_OUT="${SRCROOT}/${EXT4_OUT}" ;; esac
STAMP_FILE="${EXT4_OUT}/.build-stamp"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# =============================================================================
# Self-healing: Auto-initialize submodules
# =============================================================================

if [ ! -f "${EXT4_SRC}/Cargo.toml" ]; then
    echo "${YELLOW}fs-ext4 submodule not found. Attempting to initialize...${NC}"

    # Check if we're in a git repo
    if [ ! -d "${SRCROOT}/.git" ] && [ ! -f "${SRCROOT}/.git" ]; then
        echo "${RED}ERROR: Not a git repository. Cannot auto-initialize submodules.${NC}"
        echo "Clone with: git clone --recurse-submodules <repo-url>"
        exit 1
    fi

    # Try to initialize submodule
    if [ -f "${SRCROOT}/.gitmodules" ]; then
        echo "${YELLOW}Running: git submodule update --init --recursive${NC}"
        cd "$SRCROOT"
        if ! git submodule update --init --recursive 2>/dev/null; then
            echo "${YELLOW}Trying alternative: git submodule update --init vendor/rust-fs-ext4${NC}"
            git submodule update --init vendor/rust-fs-ext4 2>/dev/null || true
        fi
    fi

    # Check again
    if [ ! -f "${EXT4_SRC}/Cargo.toml" ]; then
        echo "${RED}ERROR: fs-ext4 submodule could not be initialized.${NC}"
        echo "Manual fix: cd ${SRCROOT} && git submodule add https://github.com/christhomas/rust-fs-ext4 vendor/rust-fs-ext4"
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
    echo "Or run: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    exit 1
fi

if ! command -v rustup &> /dev/null; then
    echo "${RED}ERROR: rustup is not installed (needed for cross-compilation).${NC}"
    echo "Install Rust from https://rustup.rs/"
    exit 1
fi

# Check if we need to rebuild
needs_rebuild() {
    # No stamp file = never built
    if [ ! -f "$STAMP_FILE" ]; then
        return 0
    fi

    # Check if any Rust source files are newer than stamp
    local newest_source
    newest_source=$(find "${EXT4_SRC}/src" -name "*.rs" -newer "$STAMP_FILE" 2>/dev/null | head -1)
    if [ -n "$newest_source" ]; then
        echo "${YELLOW}fs-ext4: Source files changed, rebuilding...${NC}"
        return 0
    fi

    # Check if Cargo.toml changed
    if [ "${EXT4_SRC}/Cargo.toml" -nt "$STAMP_FILE" ]; then
        echo "${YELLOW}fs-ext4: Cargo.toml changed, rebuilding...${NC}"
        return 0
    fi

    # Check if output is missing
    if [ ! -d "${EXT4_OUT}/fs_ext4.xcframework" ]; then
        echo "${YELLOW}fs-ext4: XCFramework missing, rebuilding...${NC}"
        return 0
    fi

    return 1
}

# Skip if up to date
if ! needs_rebuild; then
    echo "${GREEN}fs-ext4: Up to date${NC}"
    exit 0
fi

echo "${YELLOW}Building fs-ext4 from ${EXT4_SRC}...${NC}"

# Ensure Rust targets are installed
for target in aarch64-apple-darwin x86_64-apple-darwin; do
    if ! rustup target list --installed 2>/dev/null | grep -q "^${target}$"; then
        echo "${YELLOW}Installing Rust target: ${target}${NC}"
        rustup target add "${target}"
    fi
done

# Build for both architectures
echo "Building for arm64..."
cd "${EXT4_SRC}"
cargo build --release --target aarch64-apple-darwin

echo "Building for x86_64..."
cargo build --release --target x86_64-apple-darwin

# Create output directories
mkdir -p "${EXT4_OUT}/include"

# Create universal binary with lipo
echo "Creating universal binary..."
lipo -create \
    "${EXT4_SRC}/target/aarch64-apple-darwin/release/libfs_ext4.a" \
    "${EXT4_SRC}/target/x86_64-apple-darwin/release/libfs_ext4.a" \
    -output "${EXT4_OUT}/libfs_ext4.a"

# Copy headers
cp "${EXT4_SRC}/include/fs_ext4.h" "${EXT4_OUT}/include/fs_ext4.h"

# Create XCFramework
echo "Creating XCFramework..."
rm -rf "${EXT4_OUT}/fs_ext4.xcframework"
xcodebuild -create-xcframework \
    -library "${EXT4_OUT}/libfs_ext4.a" \
    -headers "${EXT4_OUT}/include" \
    -output "${EXT4_OUT}/fs_ext4.xcframework" \
    2>/dev/null

# Update stamp file
touch "$STAMP_FILE"

echo "${GREEN}fs-ext4 build complete${NC}"
echo "  XCFramework: ${EXT4_OUT}/fs_ext4.xcframework"
echo "  Architectures: $(lipo -info "${EXT4_OUT}/libfs_ext4.a" | cut -d: -f3)"
