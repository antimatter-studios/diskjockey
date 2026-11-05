#!/usr/bin/env bash
# Every crate under rust-bundles/ pins one Rust toolchain, the same one.
#
# make vendor-bundles builds each crate with whatever rustc its directory
# selects. A crate with no rust-toolchain.toml gets the machine's `stable`,
# which on a Mac last updated in 2022 is cargo 1.64.0: it cannot read a
# version 4 Cargo.lock, so vendor-all stops after the filesystem bundles
# (#575). CI installs a current stable and never sees it. A crate pinned to
# a different channel builds, and links into the app beside archives from
# another rustc, which is what the pins exist to prevent
# (scripts/bump-toolchain.sh).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

channel_of() {
    sed -nE 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$1" | head -1
}

crates=0
first=""
for manifest in "$ROOT"/rust-bundles/*/Cargo.toml; do
    [ -f "$manifest" ] || continue
    crates=$((crates + 1))
    dir="$(dirname "$manifest")"
    name="$(basename "$dir")"
    toml="$dir/rust-toolchain.toml"
    if [ ! -f "$toml" ]; then
        fail "$name has no rust-toolchain.toml, so it builds with the machine's stable"
        continue
    fi
    channel="$(channel_of "$toml")"
    if [ -z "$channel" ]; then
        fail "$name's rust-toolchain.toml names no channel"
        continue
    fi
    if [ -z "$first" ]; then
        first="$channel"
        first_name="$name"
    fi
    if [ "$channel" = "$first" ]; then
        ok "$name pins $channel"
    else
        fail "$name pins $channel, but $first_name pins $first"
    fi
done

# Eight crates today: seven dj-<fs>-bundle and dj-agent-image-reader. A glob
# that stops matching would otherwise pass having checked nothing.
if [ "$crates" -ge 8 ]; then
    ok "$crates crates found under rust-bundles/"
else
    fail "only $crates crates found under rust-bundles/, expected at least 8"
fi

# rustup picks the toolchain from the directory cargo runs in, not from the
# manifest it is handed: `cargo build --manifest-path rust-bundles/x/Cargo.toml`
# run from the repository root ignores x's rust-toolchain.toml and builds with
# the machine's stable. So a crate here is built from inside its directory.
for file in "$ROOT"/scripts/*.sh "$ROOT"/Makefile "$ROOT"/chores.yml "$ROOT"/.github/workflows/*.yml; do
    [ -f "$file" ] || continue
    rel="${file#"$ROOT"/}"
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        fail "$rel:${hit%%:*} builds a rust-bundles crate with --manifest-path, so its rust-toolchain.toml is not read"
    done < <(grep -nE 'cargo .*--manifest-path[ =]"?[^ ]*(rust-bundles|\$bundle)' "$file")
done
ok "the build scripts were searched for --manifest-path builds of rust-bundles crates"

[ "$fails" -ne 0 ] || echo 'rust-bundles-toolchain: all checks passed'
exit "$((fails > 0))"
