# Shared virtual-disk mount contract

This directory starts the recovery of `feat/driverkit-virtual-disk` for #385.
`DJVirtualDiskShared.h` preserves the prototype's selectors and request/list
wire layouts while making the header usable from C11 and C++.

The first slice (#392) supplies a read-only geometry validator. Its capacity
argument is the image reader's **decoded virtual size**, not the qcow2/VHDX
container's file length. It accepts a whole image or an explicit aligned
partition extent, with 512-byte or 4096-byte blocks. It rejects malformed
paths, payload sizes, reserved fields, empty geometry and out-of-range extents
without overflowing an end-offset addition. A failed call leaves its output
unchanged.

A future user client must check the incoming byte size before copying a
request into aligned local storage, validate scalar input/output counts, and
call this validator before creating a child. The backend must apply
`byteOffset` to every read, enforce per-request bounds, advertise write
protection and reject writes. The existing caller-readable file proof must
remain part of image authorization.

No DriverKit target, reader backend or mounting route is enabled by this
slice. Those follow in #393–#399. The recovered prototype's raw-file I/O and
`DKRustStubs.c` are not restored. See
[`docs/driverkit-qcow2-architecture.md`](../docs/driverkit-qcow2-architecture.md)
for the earlier design and #385 for the ordered implementation checklist.

CI runs `scripts/tests/driverkit-mount-contract.sh` in the shell tier. It
builds and runs the ABI and boundary cases as both C11 and C++17. Compile-only
validation against the installed DriverKit SDK is also possible without
activating or signing a dext.
