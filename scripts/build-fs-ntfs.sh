#!/bin/bash
# Build script for fs-ntfs (vendored pure-Rust ntfs filesystem driver)
# Called by both Xcode build phases and Makefile
#
# This script is SELF-HEALING:
# - Auto-initializes submodules if missing
# - Auto-installs Rust toolchain if needed
# - Compiles universal binary (arm64 + x86_64)
#
# Output: $NTFS_OUT/libfs_ntfs.a (universal .a) + include/fs_ntfs.h.
# The Xcode project links the .a directly via LIBRARY_SEARCH_PATHS
# + -lfs_ntfs. We no longer emit an .xcframework — it was an unused
# artifact of an earlier Xcode-linking approach.
#
# Environment variables (optional, have defaults):
#   SRCROOT    - Project root (default: pwd)
#   NTFS_SRC   - Path to Rust source (default: $SRCROOT/vendor/rust-fs-ntfs)
#   NTFS_OUT   - Path for build output (default: $SRCROOT/lib/fs_ntfs)

set -e

# Configuration with defaults
SRCROOT="${SRCROOT:-$(pwd)}"
SRCROOT="$(cd "${SRCROOT}" && pwd)"
NTFS_SRC="${NTFS_SRC:-${SRCROOT}/vendor/rust-fs-ntfs}"
NTFS_OUT="${NTFS_OUT:-${SRCROOT}/lib/fs_ntfs}"
case "$NTFS_SRC" in /*) ;; *) NTFS_SRC="${SRCROOT}/${NTFS_SRC}" ;; esac
case "$NTFS_OUT" in /*) ;; *) NTFS_OUT="${SRCROOT}/${NTFS_OUT}" ;; esac
STAMP_FILE="${NTFS_OUT}/.build-stamp"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# =============================================================================
# Self-healing: Auto-initialize submodules
# =============================================================================

if [ ! -f "${NTFS_SRC}/Cargo.toml" ]; then
    echo "${YELLOW}fs-ntfs submodule not found. Attempting to initialize...${NC}"

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
            echo "${YELLOW}Trying alternative: git submodule update --init vendor/rust-fs-ntfs${NC}"
            git submodule update --init vendor/rust-fs-ntfs 2>/dev/null || true
        fi
    fi

    # Check again
    if [ ! -f "${NTFS_SRC}/Cargo.toml" ]; then
        echo "${RED}ERROR: fs-ntfs submodule could not be initialized.${NC}"
        echo "Manual fix: cd ${SRCROOT} && git submodule add https://github.com/christhomas/rust-fs-ntfs vendor/rust-fs-ntfs"
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

# Emit VERSION.txt manifest describing the submodule commit that was built.
# Defined up here (not after the build) so the skip-if-up-to-date path can
# ALSO re-emit the manifest: the `.a` may be current, but the submodule may
# have been re-pointed or the working tree may have flipped clean↔dirty
# since the last build, and `needs_rebuild` doesn't track either of those.
# Always re-emitting keeps the manifest honest with no rebuild cost.
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

        if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
            dirty="false"
        else
            dirty="true"
        fi

        if tag=$(git describe --tags --exact-match 2>/dev/null); then
            ref="$tag"
            ref_type="tag"
        elif branch=$(git symbolic-ref --short -q HEAD 2>/dev/null); then
            ref="$branch"
            ref_type="branch"
        else
            ref="HEAD"
            ref_type="detached"
        fi

        # Commit date (ISO 8601 with timezone) — identifies the source, not the
        # local build time. Parseable by Swift's ISO8601DateFormatter.
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

# Check if we need to rebuild
needs_rebuild() {
    # No stamp file = never built
    if [ ! -f "$STAMP_FILE" ]; then
        return 0
    fi

    # Check if any Rust source files are newer than stamp
    local newest_source
    newest_source=$(find "${NTFS_SRC}/src" -name "*.rs" -newer "$STAMP_FILE" 2>/dev/null | head -1)
    if [ -n "$newest_source" ]; then
        echo "${YELLOW}fs-ntfs: Source files changed, rebuilding...${NC}"
        return 0
    fi

    # Check if Cargo.toml changed
    if [ "${NTFS_SRC}/Cargo.toml" -nt "$STAMP_FILE" ]; then
        echo "${YELLOW}fs-ntfs: Cargo.toml changed, rebuilding...${NC}"
        return 0
    fi

    # Check if output is missing
    if [ ! -f "${NTFS_OUT}/libfs_ntfs.a" ]; then
        echo "${YELLOW}fs-ntfs: static lib missing, rebuilding...${NC}"
        return 0
    fi

    return 1
}

# Skip compilation if up to date — but ALWAYS refresh the manifest so the
# dirty flag / ref / commit stay current even when no .rs file changed.
if ! needs_rebuild; then
    emit_version_manifest "fs_ntfs" "${NTFS_SRC}" "${NTFS_OUT}/VERSION.txt"
    echo "${GREEN}fs-ntfs: Up to date${NC}"
    exit 0
fi

echo "${YELLOW}Building fs-ntfs from ${NTFS_SRC}...${NC}"

# cd into the submodule first so rust-toolchain.toml overrides apply;
# otherwise rustup target commands run against the wrong toolchain and
# cargo later fails to find std/core for the missing target.
cd "${NTFS_SRC}"

# Ensure Rust targets are installed (for the toolchain pinned by the crate)
for target in aarch64-apple-darwin x86_64-apple-darwin; do
    if ! rustup target list --installed 2>/dev/null | grep -q "^${target}$"; then
        echo "${YELLOW}Installing Rust target: ${target}${NC}"
        rustup target add "${target}"
    fi
done

# Build for both architectures
echo "Building for arm64..."
cargo build --release --target aarch64-apple-darwin

echo "Building for x86_64..."
cargo build --release --target x86_64-apple-darwin

# Create output directories
mkdir -p "${NTFS_OUT}/include"

# Create universal binary with lipo
echo "Creating universal binary..."
lipo -create \
    "${NTFS_SRC}/target/aarch64-apple-darwin/release/libfs_ntfs.a" \
    "${NTFS_SRC}/target/x86_64-apple-darwin/release/libfs_ntfs.a" \
    -output "${NTFS_OUT}/libfs_ntfs.a"

# Copy fs_ntfs.h alongside the static lib. fs_core.h comes from the
# sister fs-core crate (still a transitive Cargo dep, so its symbols
# ride into libfs_ntfs.a). The disk-image container headers
# (qcow2.h / vhd.h / vhdx.h / vmdk.h) are NOT copied here — those
# crates are built separately into lib/img_*/ by
# scripts/build-img-containers.sh, and consumers link each .a
# individually. See `feedback_no_cross_domain_bundling` for why we
# don't bundle them through this lib.
cp "${NTFS_SRC}/include/fs_ntfs.h" "${NTFS_OUT}/include/fs_ntfs.h"
FS_CORE_HDR="${SRCROOT}/vendor/rust-fs-core/include/fs_core.h"
[ -f "$FS_CORE_HDR" ] && cp "$FS_CORE_HDR" "${NTFS_OUT}/include/fs_core.h"

emit_version_manifest "fs_ntfs" "${NTFS_SRC}" "${NTFS_OUT}/VERSION.txt"

# Update stamp file
touch "$STAMP_FILE"

echo "${GREEN}fs-ntfs build complete${NC}"
echo "  Static lib:    ${NTFS_OUT}/libfs_ntfs.a"
echo "  Architectures: $(lipo -info "${NTFS_OUT}/libfs_ntfs.a" | cut -d: -f3)"
echo "  Manifest:      ${NTFS_OUT}/VERSION.txt"
