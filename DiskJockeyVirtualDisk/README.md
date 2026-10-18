# Virtual-disk service scaffold and mount contract

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

The service scaffold (#393) restores `DJVirtualDiskService` and a separate
DriverKit target. Start calls the superclass and registers the service; a
registration failure unwinds the superclass start. Stop delegates to the
superclass. The app embeds the dext at `Contents/Library/SystemExtensions`.
No media, user client, reader backend or mounting route is enabled. Those
follow in #394–#399. The recovered prototype's raw-file I/O and
`DKRustStubs.c` are not restored. See
[`docs/driverkit-qcow2-architecture.md`](../docs/driverkit-qcow2-architecture.md)
for the earlier design and #385 for the ordered implementation checklist.

CI runs `scripts/tests/driverkit-mount-contract.sh` in the shell tier. It
builds and runs the ABI and boundary cases as both C11 and C++17. Compile-only
validation against the installed DriverKit SDK is also possible without
activating or signing a dext.

## Build and activation prerequisites

Build the service without vendored libraries or a signing identity:

```sh
xcodebuild -project DiskJockey.xcodeproj -target DiskJockeyVirtualDisk \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

This compiles the `.iig` with the installed DriverKit SDK and links only
DriverKit. No macOS Rust archive, replacement Rust symbol or Mach-O platform
rewrite is involved. The existing app build still needs `make vendor-all`.

An unsigned build does not prove activation. Apple must grant the
[DriverKit entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit)
for `com.antimatterstudios.diskjockey.virtualdisk`; sign the dext with a
provisioning profile carrying that capability. An activation host also needs
a signed containing application with the System Extension installation
capability, an activation harness using `OSSystemExtensionRequest`, and user
approval. This slice adds no activation UI or installation entitlement to the
shipping app. A future block-device slice must separately obtain and provision
the storage-family capability; this IOService-only scaffold does not use it.

On that provisioned host, activate the embedded bundle and inspect
`ioreg -l -w0 -c IOUserService` for an entry whose `IOUserClass` is
`DJVirtualDiskService` and whose `IOUserServerName` is the dext bundle ID. Then
deactivate it through the same harness and verify that entry disappears.
Also confirm no new `/dev/diskN` appears. Retain the activation/deactivation
completion results and system log with the evidence. Without the profile or
harness, runtime validation is **blocked by provisioning prerequisites**, not
passed or skipped. The shell project guard checks packaging and source
membership only; it cannot certify runtime registration or shutdown.

## Reader boundary

#418 measured whether the qcow2 reader can run inside the dext rather than
assuming it. `scripts/driverkit-reader-probe.sh` builds the rust-img-qcow2
release the bundles lock, with Rust's std, for the DriverKit platform: a
nightly `-Zbuild-std` build against an `arm64-apple-driverkit` LLVM target, so
the objects carry the DRIVERKIT platform rather than a retagged macOS one.
It then links them the way a dext is linked, against DriverKit.framework and
libc++ from the installed DriverKit SDK, with Apple's linker as the judge.

Measured on 2026-10-18 with the DriverKit 25.2 SDK, nightly 1.97.0 and
rust-img-qcow2 0.6.1: the link is refused with 175 unresolved symbols. They
include `malloc`, `free`, `open`, `pread`, `close`, `mmap`, `pthread_create`,
`pthread_mutex_lock`, `__tlv_bootstrap`, `__error` and
`CCRandomGenerateBytes`. DriverKit's libSystem names only Apple's own
libraries as allowable clients, and DriverKit.framework does not export these
symbols, so a third-party dext has no POSIX file, thread or TLS API to offer
the reader and cannot open the backing image at all. Defining them in the
dext is exactly the prototype's stub approach, and it stays out.

The verified boundary is therefore the **agent-to-dext read transport**: the
reader stays in `DiskJockeyAgent`, which already holds the caller's
authorization to the backing file, and the dext forwards bounded block reads
to it (#421). Re-run the probe after a DriverKit SDK or Rust release; if it
ever exits 0, record the new answer here.
