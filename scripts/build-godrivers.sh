#!/bin/bash
# Build script for Go network drivers via cgo
# Creates static library for linking with Swift/Obj-C
#
# This script:
# 1. Checks if Go sources have changed since last build
# 2. Compiles Go code as C-archive (static lib + header)
# 3. Outputs to lib/go-networkfs/ for Xcode linking
#
# Environment variables (optional, have defaults):
#   SRCROOT      - Project root (default: pwd)
#   GO_SRC       - Path to Go source (default: $SRCROOT/diskjockey-backend)
#   GO_OUT       - Path for build output (default: $SRCROOT/lib/go-networkfs)

set -e

# Configuration with defaults
SRCROOT="${SRCROOT:-$(pwd)}"
GO_SRC="${GO_SRC:-${SRCROOT}/diskjockey-backend}"
GO_OUT="${GO_OUT:-${SRCROOT}/lib/go-networkfs}"
STAMP_FILE="${GO_OUT}/.go-build-stamp"
HEADER_FILE="${GO_OUT}/gofs.h"
LIB_FILE="${GO_OUT}/libgofs.a"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if Go source exists
if [ ! -f "${GO_SRC}/go.mod" ]; then
    echo "${RED}ERROR: Go source not found at ${GO_SRC}${NC}"
    exit 1
fi

# Check if we need to rebuild
needs_rebuild() {
    # No stamp file = never built
    if [ ! -f "$STAMP_FILE" ]; then
        return 0
    fi
    
    # Check if any Go files are newer than stamp
    local newest_source
    newest_source=$(find "${GO_SRC}" -name "*.go" -newer "$STAMP_FILE" 2>/dev/null | head -1)
    if [ -n "$newest_source" ]; then
        echo "${YELLOW}gofs: Go source files changed, rebuilding...${NC}"
        return 0
    fi
    
    # Check if go.mod changed
    if [ "${GO_SRC}/go.mod" -nt "$STAMP_FILE" ]; then
        echo "${YELLOW}gofs: go.mod changed, rebuilding...${NC}"
        return 0
    fi
    
    # Check if output is missing
    if [ ! -f "$LIB_FILE" ] || [ ! -f "$HEADER_FILE" ]; then
        echo "${YELLOW}gofs: Output missing, rebuilding...${NC}"
        return 0
    fi
    
    return 1
}

# Skip if up to date
if ! needs_rebuild; then
    echo "${GREEN}gofs: Up to date${NC}"
    exit 0
fi

echo "${YELLOW}Building Go network drivers from ${GO_SRC}...${NC}"

# Create output directory
mkdir -p "$GO_OUT"

# Build Go as C-archive (static library with C header)
# This creates libgofs.a and gofs.h
cd "$GO_SRC"

# Build for current architecture (Xcode handles multi-arch)
CGO_ENABLED=1 GOOS=darwin go build \
    -buildmode=c-archive \
    -o "$LIB_FILE" \
    ./cmd/gofs  # Entry point with //export functions

# Update stamp file
touch "$STAMP_FILE"

echo "${GREEN}Go drivers build complete${NC}"
echo "  Library: $LIB_FILE"
echo "  Header:  $HEADER_FILE"
echo "  Size:    $(du -h $LIB_FILE | cut -f1)"
