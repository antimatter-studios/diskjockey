#!/usr/bin/env bash
#
# c-fields-rebind-by-their-size.sh — a fixed-size C array read out of a
# driver's struct is rebound to the size of the field itself, never to a
# `capacity:` written by hand.
#
# The drivers' headers declare their strings as `char field[N]`, imported
# as tuples, and the volumes read them with `withMemoryRebound(to: CChar.self,
# capacity: N) { String(cString: $0) }`. A literal N is a second copy of the
# header, and it drifts: dirent names did it twice (dirent-names-by-length.sh),
# and am-fs-ext4 0.7.0 grew `fs_ext4_volume_info_t.volume_name` from 16 to 17
# bytes (rust-fs-ext4#463) while EXT4Backend still said 16, so a label filling
# all 16 bytes had its NUL one byte outside the rebound region. It compiles,
# it reads the right name almost always, and no build or unit test sees it.
# `MemoryLayout.size(ofValue: x.field)` takes N from the imported type.
#
# The extensions are not in the Swift package and the headers are vendored,
# not checked in, so this cannot compare a literal against N; it refuses the
# literal. Dirent names have their own guard and are skipped here.
#
#   bash scripts/tests/c-fields-rebind-by-their-size.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# scan <dir> — every `withUnsafePointer(to: a.b)` of a struct field whose
# rebind, on that line or the next two, has a literal capacity. Prints
# `file:line: text` per hit.
scan() {
    find "$1" -name '*.swift' -type f 2>/dev/null | sort | while read -r f; do
        awk -v f="$f" '
            /withUnsafePointer\(to: *[A-Za-z_][A-Za-z0-9_.]*\.[A-Za-z_][A-Za-z0-9_]*\)/ {
                left = /pointee\.name\)/ ? 0 : 3
            }
            left > 0 {
                if ($0 ~ /withMemoryRebound\(to: *[A-Za-z0-9_]+\.self, *capacity: *[0-9]+/) {
                    sub(/^[ \t]+/, ""); print f ":" FNR ": " $0; left = 0; next
                }
                left--
            }
        ' "$f"
    done
}

# --- 1. The scan refuses what it exists to refuse. ------------------------
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
mkdir -p "$SANDBOX/Vol"
cat > "$SANDBOX/Vol/Bad.swift" <<'EOF'
let a = withUnsafePointer(to: info.volume_name) { ptr in
    ptr.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
}
let b = withUnsafePointer(to: info.uuid) { $0.withMemoryRebound(to: UInt8.self, capacity: 16) { Array(UnsafeBufferPointer(start: $0, count: 16)) } }
EOF
cat > "$SANDBOX/Vol/Good.swift" <<'EOF'
let capacity = MemoryLayout.size(ofValue: info.volume_name)
let a = withUnsafePointer(to: info.volume_name) { ptr in
    ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
}
let d = withUnsafePointer(to: de.pointee.name) { ptr in
    ptr.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
}
EOF
hits="$(scan "$SANDBOX/Vol")"
if [ "$(printf '%s\n' "$hits" | grep -c 'Bad.swift')" -eq 2 ]; then
    ok "the scan finds both literal rebinds in a known-bad file"
else
    fail "the scan missed a literal rebind in a known-bad file:"$'\n'"$hits"
fi
if printf '%s\n' "$hits" | grep -q 'Good.swift'; then
    fail "the scan flagged a sized rebind, or a dirent name, in a known-good file:"$'\n'"$hits"
else
    ok "the scan passes a sized rebind, and leaves dirent names to their own guard"
fi

# --- 2. This repository's volumes. ----------------------------------------
found=0
for dir in "$REPO"/DiskJockey*/; do
    hits="$(scan "$dir")"
    [ -n "$hits" ] || continue
    found=1
    fail "$(basename "$dir") rebinds a C field to a literal capacity:"$'\n'"${hits//$REPO\//}"
done
[ "$found" -eq 0 ] && ok "no volume rebinds a C field to a hand-written capacity"

echo
if [ "$fails" -eq 0 ]; then
    echo 'c-fields-rebind-by-their-size: all checks passed'
else
    echo "c-fields-rebind-by-their-size: $fails check(s) failed" >&2
fi
exit "$((fails > 0))"
