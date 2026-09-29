#!/usr/bin/env bash
#
# dirent-names-by-length.sh — a volume takes a directory entry's name by the
# length the driver reports, through DirentName, and never rebinds the name
# array to a capacity written by hand (diskjockey#207, diskjockey#244).
#
# The name arrives as a fixed-size `char name[N]`, imported as a tuple. The
# old reader rebound it to a literal `capacity:` and scanned for the NUL with
# `String(cString:)`. The literal drifted from the header twice: SquashFS's
# array is 257 bytes and the Swift said 256; NTFS's is 1024
# (FS_NTFS_DIRENT_NAME_BYTES) and the Swift said 256, so any NTFS name longer
# than 255 bytes of UTF-8 had its terminator outside the promised region.
# It compiles, it runs, and nothing visible breaks, so no build or unit test
# over the library sees it. DirentName (DiskJockeyLibrary) sizes the read
# from the imported type and takes the name by `name_len`.
#
# The extensions are not in the Swift package, so this reads their source.
# The headers are vendored and not in the checkout, so it cannot compare a
# literal against N; it refuses the literal instead.
#
#   bash scripts/tests/dirent-names-by-length.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# The volumes whose C ABI reports `name_len` and whose readers have moved to
# DirentName. A volume joins this list when it moves; it never leaves it.
volumes=(
    DiskJockeySQUASHFS/SquashfsVolume.swift
    DiskJockeyNTFS/NTFSVolume.swift
)

for rel in "${volumes[@]}"; do
    file="$REPO/$rel"
    if [ ! -f "$file" ]; then
        fail "$rel is missing"
        continue
    fi

    # A rebind of the dirent's name, and the `capacity:` it is given within
    # the next two lines (the call is usually split across lines).
    rebinds="$(grep -n -A2 'withUnsafePointer(to: de\.pointee\.name)' "$file" |
        grep -E 'capacity: *[0-9]+' || true)"
    if [ -z "$rebinds" ]; then
        ok "$rel does not rebind the dirent name to a hand-written capacity"
    else
        fail "$rel rebinds the dirent name to a literal capacity:"$'\n'"$rebinds"
    fi

    if grep -Eq 'DirentName\.bytes\(' "$file" &&
        grep -A2 'DirentName\.bytes(' "$file" | grep -q 'de\.pointee\.name_len'; then
        ok "$rel takes the dirent name through DirentName by name_len"
    else
        fail "$rel does not take the dirent name through DirentName.bytes(of:length: name_len)"
    fi
done

echo
if [ "$fails" -eq 0 ]; then
    echo 'dirent-names-by-length: all checks passed'
else
    echo "dirent-names-by-length: $fails check(s) failed" >&2
fi
exit "$((fails > 0))"
