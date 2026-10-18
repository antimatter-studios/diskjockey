#!/usr/bin/env bash
# CI-only integration oracle: no dext activation or local fixture run.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for tool in cargo cc qemu-img python3; do
    command -v "$tool" >/dev/null || { echo "missing $tool: install the VHDX oracle prerequisites" >&2; exit 1; }
done
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 - "$WORK/input.raw" <<'PY'
import sys
with open(sys.argv[1], 'wb') as f:
    f.truncate(32 * 1024 * 1024)
    for offset in (0, 1048576, 1048576 + 4096):
        f.seek(offset)
        f.write(bytes((i + offset // 4096) % 251 for i in range(4096)))
PY
# QEMU is an independent oracle; the adapter never writes an image.
qemu-img convert -f raw -O vhdx -o subformat=dynamic,block_size=1048576 "$WORK/input.raw" "$WORK/image.data"
qemu-img convert -f vhdx -O raw "$WORK/image.data" "$WORK/expected.raw"
qemu-img info --output=json "$WORK/image.data" > "$WORK/info.json"
python3 - "$WORK" <<'PY'
import json, os, sys
root = sys.argv[1]
assert json.load(open(root + '/info.json'))['virtual-size'] == os.stat(root + '/expected.raw').st_size
PY
cargo build --locked --manifest-path "$ROOT/rust-bundles/dj-agent-image-reader/Cargo.toml"
cc -std=c11 -D_XOPEN_SOURCE=700 -Wall -Wextra -Werror \
    -I "$ROOT/DiskJockeyAgent" "$ROOT/scripts/tests/fixtures/agent-vhdx-reader.c" \
    "$ROOT/rust-bundles/dj-agent-image-reader/target/debug/libdj_agent_image_reader.a" \
    -framework Security -framework CoreFoundation -liconv -lresolv -lpthread -ldl -lm -o "$WORK/oracle"
"$WORK/oracle" "$WORK/image.data" "$WORK/expected.raw"
