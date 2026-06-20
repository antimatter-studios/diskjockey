#!/usr/bin/env bash
#
# build-bundles.sh — build the per-extension aggregator staticlibs.
#
# Each DiskJockey FSKit extension links ONE Rust staticlib that combines its
# filesystem driver with the disk-image container readers, so std is linked
# exactly once (separate per-crate staticlibs collide on _rust_eh_personality;
# macOS ld64 has no allow-multiple-definition). The bundle crates live in
# rust-bundles/dj-<fs>-bundle and depend on the PUBLISHED crates.io versions,
# so a distribution build needs no submodule layout. Code AND C headers are
# taken from the resolved crates.io packages.
#
# For local co-development (hack a driver without publishing), see
# scripts/dev-link.sh / `make dev-link FS=<fs>`.
#
# Output per fs: lib/bundle_<fs>/{libdj_<fs>_bundle.a, include/*.h, VERSION.txt}
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
target="aarch64-apple-darwin"
GREEN='\033[0;32m'; NC='\033[0m'

for fs in ext4 ntfs erofs squashfs; do
    bundle="$root/rust-bundles/dj-${fs}-bundle"
    out="$root/lib/bundle_${fs}"
    [ -d "$bundle" ] || { echo "missing bundle crate: $bundle" >&2; exit 1; }
    echo "\nBuilding dj-${fs}-bundle..."
    mkdir -p "$out/include"

    # `--locked` would be ideal, but dev-link toggles the lock; keep it plain
    # so both distribution and dev-linked states build. Distribution state is
    # crates.io-clean (no [patch]); dev-link adds a marked override.
    ( cd "$bundle" && cargo build --release --target "$target" )
    cp "$bundle/target/${target}/release/libdj_${fs}_bundle.a" "$out/libdj_${fs}_bundle.a"

    # Pull the C headers from the resolved dependency sources (crates.io
    # registry cache, or the local submodule when dev-linked). This keeps the
    # headers in lockstep with the linked code.
    rm -f "$out"/include/*.h
    ( cd "$bundle" && cargo metadata --format-version 1 ) | python3 -c '
import sys, json, os, glob, shutil
outdir = sys.argv[1]
meta = json.load(sys.stdin)
copied = []
for pkg in meta["packages"]:
    if not pkg["name"].startswith("am-"):
        continue
    src = os.path.dirname(pkg["manifest_path"])
    for h in glob.glob(os.path.join(src, "include", "*.h")):
        shutil.copy(h, outdir)
        copied.append(os.path.basename(h))
print("  headers: " + " ".join(sorted(copied)))
' "$out/include"

    # Provenance: record the resolved crate versions that went into this bundle.
    ( cd "$bundle" && cargo metadata --format-version 1 ) | python3 -c '
import sys, json
meta = json.load(sys.stdin)
deps = sorted((p["name"], p["version"]) for p in meta["packages"] if p["name"].startswith("am-"))
print("bundle resolved crates (crates.io unless dev-linked):")
for n, v in deps:
    print(f"  {n} {v}")
' > "$out/VERSION.txt"

    echo "${GREEN}  -> $out/libdj_${fs}_bundle.a${NC}"
done
echo "\n${GREEN}all bundles built${NC}"
