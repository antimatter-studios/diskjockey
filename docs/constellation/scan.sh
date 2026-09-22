#!/bin/bash
# Evidence for: is there a layer of shared behaviour above am-fs-core
# that the driver and image crates each re-implement?
#
# Writes $CLAUDE_JOB_DIR/tmp/constellation-evidence.txt. Set
# CLAUDE_JOB_DIR to anywhere writable:
#
#     CLAUDE_JOB_DIR=/tmp docs/constellation/scan.sh
#
# Expects the sibling crates checked out beside this repository, which
# is the same layout `scripts/sibling-build.sh` assumes.
#
# These are greps: they count text, not meaning. Sections 2, 6 and 13
# are known to under- or over-count — see the "How to read it" section
# of the evidence document for which and why.
set -u
# The siblings live beside this repository, not inside it.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.." || exit 1
OUT="${CLAUDE_JOB_DIR:?set CLAUDE_JOB_DIR to a writable directory}/tmp/constellation-evidence.txt"
mkdir -p "$(dirname "$OUT")"
: > "$OUT"
REPOS="rust-fs-ext4 rust-fs-ntfs rust-fs-xfs rust-fs-btrfs rust-fs-erofs rust-fs-squashfs rust-img-qcow2 rust-img-vhd rust-img-vhdx rust-img-vmdk rust-partitions rust-lzo1x rust-blk-probe"

say() { echo "$@" >> "$OUT"; }

# A SIBLING THAT IS NOT HERE IS NOT A ZERO (#104). Every count below reads
# `$r/src` with its errors discarded, so a crate that is not checked out
# printed the same `0` as one with genuinely nothing to count, and the
# evidence document could not tell the two apart. Refuse a partial
# constellation rather than report it.
missing=""
for r in $REPOS; do
  [ -d "$r/src" ] || missing="$missing $r"
done
if [ -n "$missing" ]; then
  echo "scan.sh: not checked out beside this repository:$missing" >&2
  echo "scan.sh: a missing crate would read as a count of 0, so nothing was written" >&2
  rm -f "$OUT"
  exit 1
fi

say "=== 1. SIZE ==="
printf '%-18s %8s %8s\n' repo src tests >> "$OUT"
for r in $REPOS; do
  s=$(find "$r/src" -name '*.rs' 2>/dev/null -exec cat {} + | wc -l | tr -d ' ')
  t=$(find "$r/tests" -name '*.rs' 2>/dev/null -exec cat {} + | wc -l | tr -d ' ')
  printf '%-18s %8s %8s\n' "$r" "$s" "$t" >> "$OUT"
done

say ""
say "=== 2. ENDIAN HELPERS (per-crate fn definitions) ==="
for r in $REPOS; do
  # SUMMED BY awk, NOT bc: `bc` is absent on many machines (this project's
  # Raspberry Pi included), and `bc 2>/dev/null` plus `${n:-0}` printed 0.
  n=$(grep -rhcE "^\s*(pub(\(crate\))? )?(const )?fn (read_)?(le|be)_?(u)?(8|16|32|64)" "$r/src" | awk '{ s += $1 } END { print s + 0 }')
  say "$r: $n"
  grep -rnE "^\s*(pub(\(crate\))? )?(const )?fn (read_)?(le|be)_?(u)?(8|16|32|64)" "$r/src" 2>/dev/null | sed "s|^|    |" >> "$OUT"
done

say ""
say "=== 3. CHECKSUM IMPLEMENTATIONS ==="
grep -rn "fn crc32\|fn linux_crc32c\|const CRC32\|CRC32C_TABLE\|fn compute_checksum\|fn checksum" $(for r in $REPOS; do echo "$r/src"; done) 2>/dev/null >> "$OUT"

say ""
say "=== 4. IN-MEMORY TEST DEVICES ==="
grep -rn "struct MemDev\|struct MemoryDevice\|struct MemBlockDevice\|struct InMemoryDevice\|struct TestDevice" $(for r in $REPOS; do echo "$r/src" "$r/tests"; done) 2>/dev/null >> "$OUT"

say ""
say "=== 5. LOGICAL->PHYSICAL MAPPING (the extent/run/BAT/grain family) ==="
grep -rn "fn map_logical\|fn lookup_cluster\|fn find_run_for_vcn\|fn locate\|fn resolve_block\|fn block_for\|fn translate" $(for r in $REPOS; do echo "$r/src"; done) 2>/dev/null >> "$OUT"

say ""
say "=== 6. ALLOCATION BITMAPS ==="
grep -rn "fn.*bitmap.*(get\|set\|test\|clear\|alloc\|free)\|fn bitmap_\|fn set_bit\|fn clear_bit\|fn test_bit" $(for r in $REPOS; do echo "$r/src"; done) 2>/dev/null | head -60 >> "$OUT"

say ""
say "=== 7. FFI PANIC GUARDS ==="
grep -rn "fn ffi_guard\|catch_unwind" $(for r in $REPOS; do echo "$r/src"; done) 2>/dev/null >> "$OUT"

say ""
say "=== 8. ERROR ENUMS: variants per crate ==="
for r in $REPOS; do
  n=$(grep -cE "^\s{4}[A-Z][A-Za-z0-9]*(\s*\{|\(|,)" "$r/src/error.rs" 2>/dev/null)
  say "$r: ${n:-no error.rs}"
done

say ""
say "=== 9. SHARED ERROR VARIANT NAMES ACROSS CRATES ==="
for r in $REPOS; do
  grep -hoE "^\s{4}[A-Z][A-Za-z0-9]*" "$r/src/error.rs" 2>/dev/null | tr -d ' '
done | sort | uniq -c | sort -rn | head -30 >> "$OUT"

say ""
say "=== 10. OFFSET-TABLE CONVENTIONS ==="
for r in $REPOS; do
  n=$(grep -rc "mod offsets" "$r/src" 2>/dev/null | grep -v ':0' | wc -l | tr -d ' ')
  h=$(grep -rhoE "\[0x[0-9a-fA-F]+\.\.0x[0-9a-fA-F]+\]" "$r/src" 2>/dev/null | wc -l | tr -d ' ')
  say "$r: offsets-modules=$n inline-hex-ranges=$h"
done

say ""
say "=== 11. TIMESTAMP CONVERSION ==="
grep -rn "fn nt_time\|fn unix_to\|fn to_unix\|EPOCH\|fn nt_parts\|1601\|11644473600" $(for r in $REPOS; do echo "$r/src"; done) 2>/dev/null | head -30 >> "$OUT"

say ""
say "=== 12. CACHES ==="
grep -rn "struct .*Cache\b" $(for r in $REPOS; do echo "$r/src"; done) 2>/dev/null >> "$OUT"

say ""
say "=== 13. DIRECTORY ITERATION ==="
grep -rn "struct .*DirIter\|struct .*Iter<\|fn iter_dir\|fn read_dir\|fn list_dir" $(for r in $REPOS; do echo "$r/src"; done) 2>/dev/null | head -40 >> "$OUT"

say ""
say "=== 14. CARGO DEPENDENCIES (what each crate actually shares) ==="
for r in $REPOS; do
  say "--- $r"
  sed -n '/^\[dependencies\]/,/^\[/p' "$r/Cargo.toml" 2>/dev/null | grep -E "^[a-z]" >> "$OUT"
done
echo "DONE" >> "$OUT"
