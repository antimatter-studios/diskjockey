#!/usr/bin/env bash
#
# path-encoding-matches-pin.sh — no FSKit volume hands its driver a path's raw
# bytes unless the driver release its bundle pins reads them as bytes
# (diskjockey#254).
#
# Each volume declares a DriverPathEncoding (#251). `.bytes` hands the driver
# a name exactly as its dirents reported it; `.utf8` refuses a non-UTF-8 name
# with EILSEQ before any C call. The declaration is only safe beside the right
# crate version, and the two live in different files that nothing else
# compares: am-fs-erofs 0.2.0 and am-fs-ext4 0.5.1 answer an undecodable path
# as the ROOT, with success, so a `.bytes` volume over either would stat the
# root in place of the file, and on ext4 unlink or rename it. That builds
# cleanly and passes every mock-driver test.
#
# The table below is the first release of each driver whose C ABI reads an
# in-image path as the bytes up to the NUL. The guard reads each bundle's
# Cargo.lock and each volume's declaration, and fails on a `.bytes` volume
# whose pinned driver is older than that.
#
# A `.utf8` volume over a byte-exact driver is safe, only needlessly strict,
# so it is reported but not failed: ext4 stays there until its release.
#
#   bash scripts/tests/path-encoding-matches-pin.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
note() { printf 'note  %s\n' "$1"; }

# fs | first byte-exact release | file declaring the encoding
table='
erofs    0.3.0  DiskJockeyEROFS/ErofsVolume.swift
squashfs 0.3.0  DiskJockeySQUASHFS/SquashfsVolume.swift
btrfs    0.8.0  DiskJockeyBTRFS/BtrfsVolume.swift
xfs      0.9.0  DiskJockeyXFS/XfsVolume.swift
ext4     0.6.0  DiskJockeyEXT4/EXT4Backend.swift
'

# at_least A B: A >= B as dotted versions.
at_least() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }

pinned() { # <fs> — the am-fs-<fs> version the bundle's lockfile resolves
    awk -v n="am-fs-$1" '
        $0 == "name = \"" n "\"" { hit = 1; next }
        hit && /^version = / { gsub(/version = |"/, ""); print; exit }
    ' "$REPO/rust-bundles/dj-$1-bundle/Cargo.lock" 2>/dev/null
}

declared() { # <file> — bytes | utf8, from `pathEncoding: DriverPathEncoding = .X`
    sed -n 's/.*let pathEncoding: DriverPathEncoding = \.\([a-z0-9]*\).*/\1/p' "$REPO/$1" 2>/dev/null
}

while read -r fs first file; do
    [ -n "$fs" ] || continue
    version="$(pinned "$fs")"
    if [ -z "$version" ]; then
        fail "$fs: rust-bundles/dj-$fs-bundle/Cargo.lock resolves no am-fs-$fs"
        continue
    fi
    encoding="$(declared "$file")"
    where="$file"
    if [ "$(printf '%s\n' "$encoding" | grep -c .)" -ne 1 ]; then
        fail "$fs: $file does not declare exactly one pathEncoding (found [${encoding//$'\n'/ }])"
        continue
    fi
    case "$encoding" in
        bytes)
            if at_least "$version" "$first"; then
                ok "$fs: .bytes over am-fs-$fs $version, byte-exact since $first"
            else
                fail "$fs: .bytes ($where) over am-fs-$fs $version, which decodes paths as UTF-8; byte-exact from $first"
            fi ;;
        utf8)
            if at_least "$version" "$first"; then
                note "$fs: .utf8 over am-fs-$fs $version, which is byte-exact; $where can declare .bytes"
            fi
            ok "$fs: .utf8 over am-fs-$fs $version never hands the driver a non-UTF-8 path" ;;
        *)
            fail "$fs: $where declares an encoding this guard does not know: .$encoding" ;;
    esac
done <<< "$table"

echo
if [ "$fails" -eq 0 ]; then
    echo 'path-encoding-matches-pin: all checks passed'
else
    echo "path-encoding-matches-pin: $fails check(s) failed" >&2
fi
exit "$((fails > 0))"
