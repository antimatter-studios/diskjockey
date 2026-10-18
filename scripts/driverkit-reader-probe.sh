#!/usr/bin/env bash
#
# driverkit-reader-probe.sh — can the qcow2 reader run inside the dext? (#418)
#
# Builds the rust-img-qcow2 release the bundles lock, together with Rust's std,
# for the DriverKit platform (an `arm64-apple-driverkit` LLVM target, objects
# stamped platform DRIVERKIT), then links it into a DriverKit executable the
# way a dext is linked: DriverKit.framework and libc++, nothing else. Apple's
# linker against the installed DriverKit SDK is the oracle; nothing here
# retags a macOS archive or defines a replacement for a missing symbol.
#
#   exit 0  the reader links cleanly: a genuine DriverKit build is viable
#   exit 1  the link is refused; the unresolved symbols are in
#           <work>/unresolved.txt and their count is printed
#   exit 2  a prerequisite is missing; the message names how to provide it
#
# Needs Xcode with the DriverKit SDK, a nightly toolchain and its rust-src
# component (`-Zbuild-std` and a JSON target spec are nightly-only, and rustc
# ships no DriverKit target). Build output goes to <work>/build.log.
#
#   scripts/driverkit-reader-probe.sh [<work-dir>]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${1:-$ROOT/tmp/driverkit-reader-probe}"
LOCK="$ROOT/rust-bundles/dj-ext4-bundle/Cargo.lock"

missing() { printf 'driverkit-reader-probe: %s\n' "$1" >&2; exit 2; }

SDK="$(xcrun --sdk driverkit --show-sdk-path 2>/dev/null)" \
    || missing 'no DriverKit SDK: install Xcode with the DriverKit platform'
SDK_VERSION="$(xcrun --sdk driverkit --show-sdk-version 2>/dev/null)" \
    || missing 'the DriverKit SDK reports no version'
rustc +nightly --version >/dev/null 2>&1 \
    || missing 'no nightly toolchain: rustup toolchain install nightly'
rustup component list --installed --toolchain nightly 2>/dev/null | grep -q '^rust-src' \
    || missing 'nightly lacks rust-src: rustup component add rust-src --toolchain nightly'
VERSION="$(awk '/^name = "rust-img-qcow2"$/ { getline; gsub(/[^0-9.]/, ""); print; exit }' "$LOCK")"
[ -n "$VERSION" ] || missing "no rust-img-qcow2 resolution in $LOCK"

mkdir -p "$WORK/crate/src"
cat > "$WORK/crate/Cargo.toml" <<EOF
[package]
name = "driverkit-reader-probe"
version = "0.0.0"
edition = "2021"
publish = false

[lib]
crate-type = ["staticlib"]

[dependencies]
rust-img-qcow2 = "=$VERSION"

[profile.release]
panic = "abort"

[workspace]
EOF
printf 'extern crate img_qcow2;\n' > "$WORK/crate/src/lib.rs"

# The DriverKit spec is macOS's spec with the DriverKit LLVM target. rustc
# appends the deployment version itself and refuses a versioned triple.
rustc +nightly -Z unstable-options --print target-spec-json --target aarch64-apple-darwin \
    | python3 -c '
import json, sys
spec = json.load(sys.stdin)
spec["llvm-target"] = "arm64-apple-driverkit"
spec.pop("is-builtin", None)
json.dump(spec, sys.stdout, indent=1)
' > "$WORK/aarch64-apple-driverkit.json"

if ! CARGO_TARGET_DIR="$WORK/target" cargo +nightly build --release \
        -Zbuild-std=std,panic_abort -Zjson-target-spec \
        --manifest-path "$WORK/crate/Cargo.toml" \
        --target "$WORK/aarch64-apple-driverkit.json" > "$WORK/build.log" 2>&1; then
    printf 'driverkit-reader-probe: the DriverKit build failed; see %s\n' "$WORK/build.log" >&2
    exit 1
fi
ARCHIVE="$WORK/target/aarch64-apple-driverkit/release/libdriverkit_reader_probe.a"

printf 'void *qcow2_open(const char *path);\nint main(void) { return qcow2_open("/") != 0; }\n' \
    > "$WORK/main.c"
xcrun --sdk driverkit clang -target "arm64-apple-driverkit$SDK_VERSION" -isysroot "$SDK" \
    -F"$SDK/System/DriverKit/System/Library/Frameworks" -framework DriverKit \
    -L"$SDK/System/DriverKit/usr/lib" -lc++ \
    "$WORK/main.c" "$ARCHIVE" -o "$WORK/probe" > "$WORK/link.log" 2>&1
link_rc=$?

if grep -q 'built for' "$WORK/link.log"; then
    printf 'driverkit-reader-probe: refused, an object is not built for DriverKit; see %s\n' \
        "$WORK/link.log" >&2
    exit 1
fi
if grep -q 'Undefined symbols' "$WORK/link.log"; then
    sed -n 's/^  "\(_[^"]*\)", referenced from:$/\1/p' "$WORK/link.log" | sort -u \
        > "$WORK/unresolved.txt"
    printf 'driverkit-reader-probe: refused, %s unresolved symbols for a dext; see %s\n' \
        "$(wc -l < "$WORK/unresolved.txt" | tr -d ' ')" "$WORK/unresolved.txt" >&2
    exit 1
fi
if [ "$link_rc" -ne 0 ]; then
    printf 'driverkit-reader-probe: the link failed; see %s\n' "$WORK/link.log" >&2
    exit 1
fi
printf 'driverkit-reader-probe: rust-img-qcow2 %s links into a DriverKit executable\n' "$VERSION"
