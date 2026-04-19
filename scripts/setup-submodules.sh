#!/bin/bash
# Auto-setup script for git submodules
# Called by build scripts to ensure submodules are initialized

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ROOT_DIR="${1:-$(pwd)}"

check_and_init_submodule() {
    local path="$1"
    local name="$2"
    local url="$3"
    
    if [ -f "$path/.git" ] || [ -d "$path/.git" ]; then
        return 0
    fi
    
    if [ -d "$path" ] && [ "$(ls -A $path 2>/dev/null)" ]; then
        # Directory exists with content but not a git repo - probably already initialized
        return 0
    fi
    
    echo "${YELLOW}Initializing $name submodule...${NC}"
    
    if ! command -v git &> /dev/null; then
        echo "${RED}ERROR: git is not installed${NC}"
        exit 1
    fi
    
    cd "$ROOT_DIR"
    
    if [ -f ".gitmodules" ]; then
        git submodule update --init --recursive
    else
        echo "${YELLOW}No .gitmodules found. Attempting manual submodule add...${NC}"
        if [ -n "$url" ]; then
            git submodule add "$url" "$path" 2>/dev/null || true
            git submodule update --init --recursive
        fi
    fi
    
    if [ ! -f "$path/.git" ] && [ ! -d "$path/.git" ]; then
        echo "${RED}ERROR: Failed to initialize $name submodule${NC}"
        echo "Run manually: git submodule add $url $path"
        exit 1
    fi
    
    echo "${GREEN}✓ $name submodule initialized${NC}"
}

# Check all expected submodules
check_and_init_submodule "vendor/rust-fs-ext4" "rust-fs-ext4" "https://github.com/christhomas/rust-fs-ext4"
check_and_init_submodule "vendor/rust-fs-ntfs" "rust-fs-ntfs" "https://github.com/christhomas/rust-fs-ntfs"
check_and_init_submodule "vendor/go-networkfs" "go-networkfs" "https://github.com/christhomas/go-networkfs"

# Add more submodules here as they are added
