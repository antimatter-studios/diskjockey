#!/bin/bash
# Build script for the four disk-image container reader crates
# (am-img-qcow2, am-img-vhd, am-img-vhdx, am-img-vmdk).
#
# Each crate is built to its OWN universal static lib at lib/img_<name>/.
# We do not bundle these into libfs_ext4.a or libfs_ntfs.a — that's an
# unrelated concern. Consumers link each .a individually.
#
# Output per crate:
#   lib/img_<name>/libqcow2.a (etc.)
#   lib/img_<name>/include/<name>.h
#   lib/img_<name>/VERSION.txt
#
# Environment variables (optional):
#   SRCROOT  - Project root (default: pwd)
#
# Called by both Xcode build phases and the Makefile.

set -e

SRCROOT="${SRCROOT:-$(pwd)}"
SRCROOT="$(cd "${SRCROOT}" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# crate-name → (src-dir, lib-name-in-Cargo-toml, header-filename)
# The Cargo `[lib].name` differs from `[package].name`: e.g. the package
# `am-img-qcow2` produces a lib named `qcow2`, so `cargo build` writes
# `libqcow2.a`. Header filenames mirror the lib name.
CRATES=(
    "qcow2:rust-img-qcow2:qcow2:qcow2.h"
    "vhd:rust-img-vhd:vhd:vhd.h"
    "vhdx:rust-img-vhdx:vhdx:vhdx.h"
    "vmdk:rust-img-vmdk:vmdk:vmdk.h"
)

# Self-healing: ensure cargo + rustup are present. The fs-ext4 build
# script auto-installs the rust target; we rely on it having already
# done that, or on the user having Rust set up.
if ! command -v cargo &> /dev/null; then
    echo "${RED}ERROR: Rust/Cargo is not installed.${NC}"
    echo "Install from: https://rustup.rs/"
    exit 1
fi
if ! command -v rustup &> /dev/null; then
    echo "${RED}ERROR: rustup is not installed (needed for cross-compilation).${NC}"
    exit 1
fi

# Emit a VERSION.txt manifest for the built crate so the host app's
# About / Diagnostics pane can surface the exact submodule commit.
# Mirror of the function in scripts/build-fs-ext4.sh — kept as a copy
# rather than sourced so each script stays independently runnable.
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

# Build one crate. Lipo's a universal binary, copies its header,
# emits the manifest.
build_one() {
    local key="$1"
    IFS=':' read -r name src_subdir lib_name header_name <<< "$key"

    local src_dir="${SRCROOT}/vendor/${src_subdir}"
    local out_dir="${SRCROOT}/lib/img_${name}"
    local stamp="${out_dir}/.build-stamp"

    if [ ! -f "${src_dir}/Cargo.toml" ]; then
        echo "${RED}ERROR: ${src_subdir} submodule not found at ${src_dir}${NC}"
        echo "Run: git submodule update --init --recursive"
        exit 1
    fi

    # Skip rebuild if nothing newer than the stamp.
    if [ -f "$stamp" ] && [ -f "${out_dir}/lib${lib_name}.a" ]; then
        local newest_source
        newest_source=$(find "${src_dir}/src" -name "*.rs" -newer "$stamp" 2>/dev/null | head -1)
        local cargo_newer=""
        [ "${src_dir}/Cargo.toml" -nt "$stamp" ] && cargo_newer=1
        if [ -z "$newest_source" ] && [ -z "$cargo_newer" ]; then
            emit_version_manifest "img_${name}" "${src_dir}" "${out_dir}/VERSION.txt"
            echo "${GREEN}img-${name}: up to date${NC}"
            return 0
        fi
    fi

    echo "${YELLOW}Building img-${name} from ${src_dir}...${NC}"
    cd "${src_dir}"

    # Ensure both targets are installed under whichever toolchain the
    # crate's rust-toolchain.toml pins (or the active default).
    for target in aarch64-apple-darwin x86_64-apple-darwin; do
        if ! rustup target list --installed 2>/dev/null | grep -q "^${target}$"; then
            echo "${YELLOW}Installing Rust target: ${target}${NC}"
            rustup target add "${target}"
        fi
    done

    echo "  Building for arm64..."
    cargo build --release --target aarch64-apple-darwin

    echo "  Building for x86_64..."
    cargo build --release --target x86_64-apple-darwin

    mkdir -p "${out_dir}/include"

    echo "  Creating universal binary..."
    lipo -create \
        "${src_dir}/target/aarch64-apple-darwin/release/lib${lib_name}.a" \
        "${src_dir}/target/x86_64-apple-darwin/release/lib${lib_name}.a" \
        -output "${out_dir}/lib${lib_name}.a"

    # Each crate ships its own header.
    local hdr_src="${src_dir}/include/${header_name}"
    if [ -f "$hdr_src" ]; then
        cp "$hdr_src" "${out_dir}/include/${header_name}"
    else
        echo "${YELLOW}  WARNING: header ${hdr_src} not found${NC}"
    fi

    emit_version_manifest "img_${name}" "${src_dir}" "${out_dir}/VERSION.txt"
    touch "$stamp"

    echo "${GREEN}img-${name} build complete${NC}"
    echo "  Static lib:    ${out_dir}/lib${lib_name}.a"
    echo "  Architectures: $(lipo -info "${out_dir}/lib${lib_name}.a" | cut -d: -f3)"
    echo "  Manifest:      ${out_dir}/VERSION.txt"
}

for entry in "${CRATES[@]}"; do
    build_one "$entry"
done
