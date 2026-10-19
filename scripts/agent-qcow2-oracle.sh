#!/usr/bin/env bash
# CI-only integration oracle: no dext activation or local fixture run.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for tool in cargo cc qemu-img python3; do
    command -v "$tool" >/dev/null || { echo "missing $tool: install the qcow2 oracle prerequisites" >&2; exit 1; }
done
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# A capacity that is not a cluster multiple, a partition table, data at a
# partition offset and a sparse range that the image never allocates.
python3 - "$WORK/input.raw" <<'PY'
import struct, sys
size = 32 * 1024 * 1024 + 3 * 512
with open(sys.argv[1], 'wb') as f:
    f.truncate(size)
    entry = struct.pack('<B3sB3sII', 0, b'\0\0\0', 0x83, b'\0\0\0', 2048, 4096)
    f.seek(446); f.write(entry); f.seek(510); f.write(b'\x55\xaa')
    for offset in (1048576, 1048576 + 4096, 8 * 1048576 + 512, size - 4096):
        f.seek(offset)
        f.write(bytes((i + offset // 512) % 251 for i in range(4096)))
PY
# QEMU is an independent oracle; the adapter never writes an image.
qemu-img convert -f raw -O qcow2 -o cluster_size=65536 "$WORK/input.raw" "$WORK/image.data"
qemu-img convert -f qcow2 -O raw "$WORK/image.data" "$WORK/expected.raw"
qemu-img info --output=json "$WORK/image.data" > "$WORK/info.json"
qemu-img create -q -f qcow2 -F qcow2 -b "$WORK/image.data" "$WORK/overlay.data"
python3 - "$WORK" <<'PY'
import json, os, sys
root = sys.argv[1]
virtual = json.load(open(root + '/info.json'))['virtual-size']
assert virtual == os.stat(root + '/expected.raw').st_size
assert virtual != os.stat(root + '/image.data').st_size
PY
cargo build --locked --manifest-path "$ROOT/rust-bundles/dj-agent-image-reader/Cargo.toml"
cc -std=c11 -D_XOPEN_SOURCE=700 -Wall -Wextra -Werror \
    -I "$ROOT/DiskJockeyAgent" "$ROOT/scripts/tests/fixtures/agent-qcow2-reader.c" \
    "$ROOT/rust-bundles/dj-agent-image-reader/target/debug/libdj_agent_image_reader.a" \
    -framework Security -framework CoreFoundation -liconv -lresolv -lpthread -ldl -lm -o "$WORK/oracle"
"$WORK/oracle" "$WORK/image.data" "$WORK/expected.raw" "$WORK/overlay.data"
