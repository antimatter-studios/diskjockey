# Packed pointers across the family: where else could the XFS bug live?

Audited 2026-09-06, against one question raised by a bug found in
`am-fs-xfs`:

> A pointer out of an XFS B+tree is a *packed* `fsbno` — the group
> number sitting above `sb_agblklog` bits of group-relative block — and
> the driver multiplied it by the block size as though it were a linear
> block number. Do the other readers make the same mistake with their
> own packed pointers?

The XFS bug is worth restating precisely, because the shape of it is
what this audit looked for, and it is not "a missing bounds check". Both
halves of the arithmetic were correct in isolation; what was wrong was
that two different encodings of the same idea were treated as one. It
was invisible for two independent reasons at once: it cannot appear in
group 0, and the crate's synthetic superblock gave every group exactly
1024 blocks with `agblklog` 10, so packed and linear were *equal* on
every unit-test fixture. A real 500 MB image with `agblocks` 32000
against `2^agblklog` 32768 read a group-2 tree block 12288 basic blocks
off. See `am-fs-xfs` `src/bmbt.rs:650` for the test that now pins it and
`src/bmbt.rs:413` for the ragged geometry it needs.

## What was searched for

Every place a crate turns an on-disk pointer into a device address:
anywhere a stored value is multiplied by a block or cluster size, and
anywhere bits are shifted or masked out of a stored value before it is
used as a number.

This is greps plus reading the sites they returned, so it can only find
what it looked at. It does not prove absence — it says that at each site
listed below the decode was checked by hand and found sound.

## Result: XFS was the only one

Every other crate is immune, but for three quite different reasons, and
the difference matters more than the verdict.

### The pointer is not packed at all

| crate | pointer | evidence |
|---|---|---|
| `am-fs-ext4` | block numbers are linear across the whole filesystem; a 64-bit field is split `_lo`/`_hi` across two struct fields, joined in exactly one place | `src/bgd.rs:88-97` |
| `am-fs-erofs` | `blkaddr` counts blocks from the start of the image | `src/chunked.rs:100-122` |
| `am-img-vhd`, `am-img-vmdk` | BAT and grain-directory entries are plain sector or grain counts | — |

`am-fs-ext4`'s inode-to-group arithmetic deserves a specific mention
because it is the nearest thing in the family to XFS's packing: an inode
number does divide into a group index and an index within it. It uses
`/` and `%` against `inodes_per_group` (`src/bgd.rs:208-209`), not a
shift, so it is correct for any group size rather than only for powers
of two. That is the distinction the XFS bug turned on, and ext4 is on
the right side of it by construction.

### The pointer is packed, and the split has one decode site

| crate | packing | decode site |
|---|---|---|
| `am-fs-squashfs` | metadata reference: block offset in the high 48 bits, offset within the decompressed block in the low 16 | `MetadataRef::from_packed`, `src/metablock.rs:88` |
| `am-img-qcow2` | L1/L2 entries carry COPIED (bit 63) and COMPRESSED (bit 62) above the host offset | `OFFSET_MASK`, `src/reader.rs:37`, applied at every lookup — `:1085`, `:1238`, `:1253` |
| `am-fs-ntfs` | file reference: record number in the low 48 bits, sequence number in the high 16 | masked on read at `src/read.rs:638`; encoded at `src/record_build.rs:17` |
| `am-img-vhdx` | BAT entry: payload state in the low 3 bits, bits 3–19 reserved, file offset in whole MiB above bit 20 | `BatEntry::from_u64`, `src/bat.rs:98-105`, the only decode (`src/reader.rs:582`, `:912` both call it), pinned for reserved bits by `bat_entry_ignores_reserved_bits_between_state_and_offset` (`src/bat.rs:197`); encoded open-coded at `src/reader.rs:886` |

Squashfs is the interesting row, because it was in the same position
XFS was in and is not any more: its own doc comment records that the
48/16 split used to be open-coded at three sites, with the meaning of
each half carried by a comment somewhere else entirely. One named
decode is the difference between this class of bug being possible and
not.

The one blemish here is duplication rather than a defect:
`encode_file_reference` exists twice in `am-fs-ntfs`, identically, at
`src/record_build.rs:17` and `src/mkfs.rs:1785`. Both are right today.
Two copies of a packing rule is how they stop being right together.

### The translation is a data structure, not arithmetic

`am-fs-btrfs` has no packed pointer to get wrong: a logical address
becomes a physical one through the chunk tree, an ordered
non-overlapping map (`src/chunk.rs:653`). There is no shift to omit,
because there is no shift.

## The second question: do the fixtures hide it?

What made the XFS bug survive review was not the code, it was the test
data. Every synthetic superblock in that crate gave each group a
power-of-two number of blocks, which makes the wrong answer equal to the
right one.

For the crates above the question does not arise in the same form —
where nothing is packed, no fixture geometry can hide a packing error.
It is worth stating as a rule rather than as a result, because the next
crate to grow a group-relative pointer will need it:

> A fixture whose geometry makes two encodings coincide cannot tell
> them apart. Where a format packs a pointer, at least one fixture must
> use a geometry where the packed and unpacked forms differ.

`am-fs-xfs` now has one (`v5_superblock_ragged`, `src/bmbt.rs:413`).
Nothing else in the family currently needs one.

## What this does not cover

- The three Windows drivers were not searched.
- `am-fs-ntfs` runlists decode a signed cluster delta against a running
  base, which is a different shape of address arithmetic and was not in
  scope here. It has its own tests, and no bug motivated looking at it.
- Absence of evidence: this found the decode sites the greps returned.
  A crate that spells a shift in a way the patterns missed would not
  appear above.
