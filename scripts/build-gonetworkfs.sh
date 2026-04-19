#!/bin/bash
# Build script for go-networkfs (vendored network filesystem drivers)
# Called by both Xcode build phases and Makefile
#
# This script builds SEPARATE minimal libraries per driver:
#   libftp.a - exports ftp_mount, ftp_stat, ftp_listdir...
#   libsftp.a (future) - exports sftp_mount, sftp_stat...
#
# This allows linking only needed drivers, keeping binary size small.

set -e

# Configuration with defaults
SRCROOT="${SRCROOT:-$(pwd)}"
NFS_SRC="${NFS_SRC:-${SRCROOT}/vendor/go-networkfs}"
NFS_OUT="${NFS_OUT:-${SRCROOT}/vendor/built}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Drivers to build (space-separated)
DRIVERS="${DRIVERS:-ftp}"

# =============================================================================
# Self-healing: Auto-initialize submodules
# =============================================================================

if [ ! -f "${NFS_SRC}/go.mod" ]; then
    echo "${YELLOW}go-networkfs submodule not found. Attempting to initialize...${NC}"
    
    if [ ! -d "${SRCROOT}/.git" ] && [ ! -f "${SRCROOT}/.git" ]; then
        echo "${RED}ERROR: Not a git repository. Cannot auto-initialize submodules.${NC}"
        exit 1
    fi
    
    if [ -f "${SRCROOT}/.gitmodules" ]; then
        echo "${YELLOW}Running: git submodule update --init --recursive${NC}"
        cd "$SRCROOT"
        git submodule update --init --recursive 2>/dev/null || \
            git submodule update --init vendor/go-networkfs 2>/dev/null || true
    fi
    
    if [ ! -f "${NFS_SRC}/go.mod" ]; then
        echo "${RED}ERROR: go-networkfs submodule could not be initialized.${NC}"
        echo "Manual fix: cd ${SRCROOT} && git submodule add https://github.com/christhomas/go-networkfs.git vendor/go-networkfs"
        exit 1
    fi
    
    echo "${GREEN}✓ go-networkfs submodule initialized${NC}"
fi

# =============================================================================
# Self-healing: Check Go toolchain
# =============================================================================

if ! command -v go &> /dev/null; then
    echo "${RED}ERROR: Go is not installed.${NC}"
    echo "Install from: https://go.dev/dl/"
    exit 1
fi

# =============================================================================
# Build individual driver libraries
# =============================================================================

# Create output directory
mkdir -p "$NFS_OUT"

cd "$NFS_SRC"

# Check CGO is enabled
if [ "${CGO_ENABLED:-}" = "0" ]; then
    echo "${RED}ERROR: CGO_ENABLED=0. Set CGO_ENABLED=1 to build.${NC}"
    exit 1
fi

BUILT_COUNT=0

for DRIVER in $DRIVERS; do
    STAMP_FILE="${NFS_OUT}/.${DRIVER}-stamp"
    SOURCE_DIR="${NFS_SRC}/${DRIVER}/cmd/${DRIVER}"
    
    # Check if driver exists
    if [ ! -d "$SOURCE_DIR" ]; then
        echo "${YELLOW}Driver ${DRIVER} not found at ${SOURCE_DIR}, skipping...${NC}"
        continue
    fi
    
    # Check if rebuild needed
    NEEDS_REBUILD=0
    if [ ! -f "${NFS_OUT}/lib${DRIVER}.a" ]; then
        NEEDS_REBUILD=1
    elif [ -f "$STAMP_FILE" ]; then
        # Check if source changed
        NEWER=$(find "${NFS_SRC}/${DRIVER}" -name "*.go" -newer "$STAMP_FILE" 2>/dev/null | head -1)
        if [ -n "$NEWER" ]; then
            NEEDS_REBUILD=1
        fi
    else
        NEEDS_REBUILD=1
    fi
    
    if [ $NEEDS_REBUILD -eq 0 ]; then
        echo "${GREEN}  lib${DRIVER}.a: Up to date${NC}"
        continue
    fi
    
    echo "${YELLOW}Building lib${DRIVER}.a...${NC}"
    
    # Build driver as C-archive
    CGO_ENABLED=1 GOOS=darwin go build \
        -buildmode=c-archive \
        -o "${NFS_OUT}/lib${DRIVER}.a" \
        "./${DRIVER}/cmd/${DRIVER}"
    
    # Update stamp
    touch "$STAMP_FILE"
    BUILT_COUNT=$((BUILT_COUNT + 1))
    
    echo "${GREEN}  lib${DRIVER}.a: Built ($(du -h ${NFS_OUT}/lib${DRIVER}.a | cut -f1))${NC}"
done

# Emit VERSION manifest describing the submodule commit that was built.
# One manifest per submodule (not per driver) so filename identifies the source
# repo — NFS_OUT is shared across drivers.
emit_version_manifest() {
    local lib_name="$1"
    local src_dir="$2"
    local out_file="$3"

    (
        cd "$src_dir"

        local source commit short_commit describe dirty ref ref_type built_at

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

        built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

        {
            echo "lib=${lib_name}"
            echo "source=${source}"
            echo "ref=${ref}"
            echo "ref_type=${ref_type}"
            echo "commit=${commit}"
            echo "short_commit=${short_commit}"
            echo "describe=${describe}"
            echo "dirty=${dirty}"
            echo "built_at=${built_at}"
        } > "$out_file"
    )
}

emit_version_manifest "go-networkfs" "${NFS_SRC}" "${NFS_OUT}/VERSION-go-networkfs.txt"

echo ""
echo "${GREEN}go-networkfs build complete (${BUILT_COUNT} drivers built)${NC}"
echo "  Output:   ${NFS_OUT}/"
echo "  Drivers:  ${DRIVERS}"
echo "  Manifest: ${NFS_OUT}/VERSION-go-networkfs.txt"
