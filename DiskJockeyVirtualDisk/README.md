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

## Agent-side VHDX adapter

`rust-bundles/dj-agent-image-reader` builds a **macOS host** static library for
the agent; its C ABI is `DiskJockeyAgent/DJAgentImageReader.h`. It duplicates
an already-authorized readable file descriptor without reopening a path.
The published VHDX reader verifies the content and reports decoded capacity
and logical sector size. Reads are limited to 1 MiB and the decoded image
extent; sparse ranges and reader failures retain the decoder's behavior.
There is no writable API. Close releases the duplicate; the caller keeps its
original descriptor. Callers must discard output on any failed read.

The Library tests CI job runs `scripts/agent-vhdx-oracle.sh`: QEMU produces a
dynamic VHDX under a filename without a VHDX extension and converts it back
to raw. The C consumer checks capacity, sector geometry, allocated/sparse
reads, a partition-relative sample, bounds, truncation errors and descriptor
ownership. QEMU's generated fixture uses 512-byte logical sectors; a 4096-byte
fixture remains part of provisioned-host integration. Fixture tests run in CI.

This adapter is not yet linked into the agent target and publishes no media.
#425 connects it to the shared #421 transport after #394/#419; #426 checks
failed attachments and detach during pending reads. Keep the reader out of
the dext. The agent must retain `AgentAuthority`'s caller-readable file proof,
add a selected partition offset exactly once, and serialize close with reads.

## Bounded read wire contract

`DJVirtualDiskReadShared.h` defines the version-1 request (40 bytes) and reply
header (24 bytes) for #428, the first slice of #421. These are native-endian,
same-machine C11/C++17 layouts with no pointers or file paths. The payload is
separate from the reply header: an external method call carries one structure
input, which IOKit passes only as a memory descriptor above 4096 bytes, so the
reply header travels as its five fields in `kDJReadReplyScalarCount` scalars
(`DJReadReplyToScalars`, `DJReadReplyFromScalars`, which refuses a 32-bit field
that does not fit) and the payload is the structure input (#442). A request carries nonzero device/read IDs,
decoded image offset, byte count and an absolute monotonic deadline in
nanoseconds. Read IDs must never be reused, including across reconnections.

Construct requests from validated mount geometry and the original block
read's media-relative offset/count. The constructor adds the partition offset
once, rejects overflow or misalignment, caps reads at 1 MiB (matching the
host adapter), and accepts deadlines at most 30 seconds ahead. It leaves the
output unchanged on failure. Both peers must use the same monotonic clock
and convert its ticks to nanoseconds before calling these helpers.

Copy incoming headers into aligned local storage only after checking buffer
sizes. A successful reply must match the retained request ID, protocol
version, successful status and exact byte count, with an unexpired deadline.
Short, oversized, malformed, failed or expired replies cannot authorize any
payload copy. `scripts/tests/driverkit-read-contract.sh` checks numeric field
offsets and sizes plus request/reply boundary cases as C11 and C++17.

This contract does not dispatch requests, run timers or publish block media.
#429 supplies bounded pending slots, once-only completion, timeouts without a
reply and disconnect handling; #430 wires that lifecycle through the real
user client and authorized agent reader. #419 and #425 retain block-node
oracle validation for qcow2 and VHDX respectively.

## Pending read lifecycle

`DJVirtualDiskPendingReads.h` implements #429 over injected endpoint, monotonic
clock and one-shot timer hooks. The default is 16 pending reads; capacity is
fixed at construction and excess submissions are rejected without taking a
completion. Accepted reads complete once on an exact successful reply, an
invalid matching reply, send failure, deadline, disconnect or timer failure.
Only a complete successful payload reaches the completion; errors expose no
payload. Slots are released before callbacks, including synchronous replies.

The service must own one `DJReadIdentities` sequence shared by every device
and connection for its entire lifetime. IDs never wrap or reset on reconnect;
exhaustion rejects new reads. Unknown, duplicate and stale replies do nothing.
All lifecycle calls and timer delivery must share one serial queue. The timer
hook replaces an absolute monotonic deadline and must enqueue its callback
without waiting for a reply. Failure to arm disconnects and fails all pending
work. Cancel must drain callbacks before destruction. Completion contexts must
outlive accepted reads; successful payloads are borrowed during the callback.

The shell guard drives a fake endpoint and active fake monotonic timer.
`scripts/build-driverkit-pending-reads.sh`, also run by the macOS Library tests
job, compiles and links every lifecycle path against Apple's installed
DriverKit SDK with linker warnings fatal and no POSIX or Rust replacements.
This is injected lifecycle scaffolding: #430 still owns the real user-client
endpoint and DriverKit timer hook. No media or shipping mount route is enabled.

## Agent read server

`DiskJockeyAgent/DJAgentReadServer.h` is the agent's half of one round trip
(#433). It copies an untrusted request header only after checking its length,
validates it against the mount geometry the agent authorized, and reads the
image at the request's `imageOffset` as given: the partition offset was added
once, in `DJReadRequestCreate`, and is never added again. A success reply
carries exactly the requested bytes; any reader failure or a too-small buffer
becomes `kDJReadReplyIOError` with no payload, and partial bytes are scrubbed.
A malformed, expired or out-of-geometry request produces no reply and never
reaches the reader. The reader is borrowed and already authorized by
`AgentAuthority`; the qcow2 and VHDX decoders stay in the agent and are never
linked into the dext. `scripts/tests/agent-read-server.sh` drives it with a
fake reader as C11 and C++17. The user client, agent connection and
provisioned round trip follow in #434–#437.

## User-client dispatch

`DJVirtualDiskUserClientDispatch.h` is the portable core of the user client's
read transport (#434). One table names its three selectors —
`kDJSelectorConnectReadEndpoint` (3: the protocol version as its one scalar,
with an async completion), `kDJSelectorDeliverReadReply` (4: the five
`DJReadReply` scalars and a payload of at most `kDJReadMaxBytes`) and
`kDJSelectorDisconnectReadEndpoint` (5: no arguments) — with exact scalar
counts and structure sizes and no outputs. Every count, size and completion is
checked against that table before any byte is copied; a wrong shape or an
unknown selector is refused and never touches the endpoint or a pending read.
Accepted calls route into `DJPendingReads<16>`, so at most sixteen requests are
ever outstanding at the agent. Disconnect, client death and teardown fail every
pending read and then release the endpoint's completion once.
`scripts/tests/driverkit-user-client-dispatch.sh` drives it with a fake agent
endpoint and timer: exact bytes at the translated offset, and timeout,
disconnect, short and error replies failing their block request. The DriverKit
link probe also links the core. The `IOUserClient` class itself is #435.

## DriverKit user client

`DJVirtualDiskUserClient` is the IIG class `NewUserClient` on the service
creates from the personality's `UserClientProperties`. It maps
`IOUserClientMethodArguments` onto `DJDispatchArguments`: the one structure
input, inline or a mapped descriptor, is the reply payload, and a call carrying
both is refused. The connect completion is retained only while the core owns it, and
requests reach the agent through `AsyncCompletion`. One
`IOTimerDispatchSource` on the default queue implements the arm/cancel hooks at
the absolute `CLOCK_UPTIME_RAW` deadline (`kIOTimerClockUptimeRaw`). `Stop`,
which client death also reaches, fails every pending read before the timer is
cancelled. The dext target builds with fatal warnings, and
`scripts/tests/driverkit-service-target.sh` requires the class in the target and
the personality.

## Agent read endpoint

`DJAgentReadEndpointOpen` (#443, part of #436) takes a borrowed service,
mount request, caller-opened readable descriptor and mount identity. It calls
`AgentAuthority.attachableImage` before opening either the reader or the user
client. The current host adapter is VHDX; the portable loop accepts the shared
reader ABI so decoders remain in the agent. `make vendor-bundles` now builds
the agent archive separately from the filesystem extensions.

The endpoint connects with the version scalar and an async completion. Its
main-run-loop callback receives the five packed `DJReadRequest` words, checks
the count and mount identity, then calls `DJAgentServeRead`. Replies use
`DJReadReplyToScalars` and the payload as the call's one structure input.
Disconnect, service termination, async failure or reply failure closes the
reader. Open and close must run on the main thread; close removes callback
delivery before freeing the endpoint. The host guard drives this same loop
over a fake connection. Activation and the provisioned mount round trip
remain #437.

## Agent attachment ownership lifecycle

`DiskJockeyAgent/DJAgentAttachment.hpp` (#447, part of #397) provides the
injected lifecycle for one authorized attachment and one trusted XPC
connection owner. Attachment identities must not be reused within a service
lifetime. Only a matching media event with a whole-disk `/dev/diskN` name can
complete attachment successfully. The appearance wait has an active monotonic
timer, bounded to 30 seconds. Unrelated, duplicate and late events cannot
return another device. Publication failure and connection loss enter cleanup.

Every cleanup first requests asynchronous unmount of the owned attachment,
including when its BSD name has not appeared yet. The platform hook must
resolve that identity; it must never select another disk. Only a successful,
unexpired unmount reply permits child removal. Each unmount attempt has a
fresh token, so delayed replies cannot authorize removal during a retry.
Unmount has its own 30-second deadline. Unmount or removal failure preserves
ownership and the reader/connection for a trusted retry. Resources close only
after removal, or before any publication when the appearance timer cannot arm.
Accepted attach/detach completions occur once; rejection takes no completion.

All hooks and callbacks share one serial queue. The bridge retains the core
and its hooks until `closed()` and drains timer callbacks before destruction.
The shell guard drives this production core through fake publication, disk,
unmount and timer boundaries. #448 still owns the actual XPC, IOKit and
DiskArbitration bridge and synchronized protocols; #449 owns provisioned-host
ownership evidence. #394 retains child publication, #419/#425 retain block-node
reader integration, and #420/#426 retain decoder-specific cleanup. This core
does not enable a shipping mount route or certify provisioned behavior.

## Agent media correlation

`DiskJockeyAgent/DJAgentMediaMatch.hpp` (#451, part of #448) decides whether
one DiskArbitration media event is the owned attachment's device. Only whole
media named `diskN` whose IOMedia ancestry carries the non-zero owned
`DJAttachmentIdentity` yields `/dev/diskN` for `DJAgentAttachment::appeared`.
A BSD name, path or reused disk number is never proof of ownership. The name
is checked before the registry is read. The shell guard drives the matcher
over a fake ancestry. The key, `kDJAttachmentIdentityKey`, is defined once in
`DJVirtualDiskShared.h`, which the matcher and the dext's block-device child
both include; #452 owns the IOKit ancestry search and the DiskArbitration
callback.

## Agent attachment bridge

`DiskJockeyAgent/DJAgentBridge.hpp` (#456, part of #452) owns one
attachment's platform resources. It checks `AgentAuthority.attachableImage`
against the caller's open descriptor first, then discovers the dext service,
then opens the image reader and the #443 read endpoint, and only then starts
the `DJAgentAttachment` lifecycle. A refused or invalid request opens
nothing and takes no completion. A discovery or endpoint failure releases
what was opened and starts no lifecycle. The lifecycle's close hook is the
bridge's, so the endpoint closes and the service is released exactly once,
only after removal. The shell guard drives the bridge over injected
boundaries. #457 owns the IOKit ancestry search and the DiskArbitration
callback; #458 backs publish, unmount and remove with #394's selectors.

## Mount selectors

`DiskJockeyVirtualDisk/DJVirtualDiskMountSelectors.h` (#460, part of #394) is
the portable core of the user client's mount (0), unmount (1) and list (2)
selectors. One table fixes each selector's scalar counts, structure sizes and
least output capacity, checked before any byte is copied or any slot touched.
Mount takes the non-zero attachment identity and one `DJMountRequest`, and
returns the identity as the device ID. Its geometry comes from
`DJMountRequestGetGeometry` against the decoded virtual size the injected read
backend reports for that identity. With no backend, or one that does not serve
the identity, mount fails explicitly and publishes nothing.

At most `kDJMaxVirtualDisks` media are live. A slot is reserved before the
publish hook runs and held until the remove hook succeeds, so a concurrent
request can neither take it nor reuse its identity. A failed publication
releases the slot; a failed removal keeps the child and its slot. The shell
guard drives this core over a fake backend and publisher. #461 owns block I/O,
#462 the `IOUserBlockStorageDevice` child and its `DJAttachmentIdentity`
property, and #463 the provisioned-host round trip.

## Block I/O

`DiskJockeyVirtualDisk/DJVirtualDiskBlockIO.h` (#461, part of #394) is the
portable core of one published medium's block I/O over the injected read
backend; the DriverKit child only translates `IOUserBlockStorageDevice` calls
into it. A read of `count` blocks at `lba` becomes one backend read at
`byteOffset + lba * blockSize` of `count * blockSize` bytes, every addition
and multiplication overflow-checked, and is refused when it would leave
`byteLength` or exceed `kDJReadMaxBytes`, which the transport never clamps.
Writes, unmap and zero-length reads are refused before the backend is called.

An accepted read completes exactly once, possibly before `submit` returns. It
is retired before its completion runs, so a duplicate, late or re-entrant
backend report reaches nothing. A backend that will not start the read, a
failed or timed-out read, a short read, or a success without the requested
bytes completes with an error and no bytes, never with zero-filled ones.
Teardown fails every in-flight read once. `scripts/tests/dext-block-io.sh`
compiles the header over a fake backend to prove all of this.

## Block-device child

`DiskJockeyVirtualDisk/DJVirtualDiskDevice.iig` (#462, part of #394) is the
published medium: a subclass of Apple's `IOUserBlockStorageDevice`, adapted
from the prototype's child. It is created with the non-zero attachment
identity under `kDJAttachmentIdentityKey` and the checked geometry under
`DJByteOffset`, `DJByteLength` and `DJBlockSize`, and refuses to start
without all four or with geometry the block-I/O core rejects. Start allocates
its `DJBlockIO` and sets the identity on its own registry entry, where the
agent's matcher finds it in the IOMedia ancestry. It advertises the
geometry's block size and block count, at most `kDJReadMaxBytes` per request,
as write-protected media with no unmap. Reads, writes and unmaps all go
through the core, so writes and unmaps fail `kIOReturnNotWritable`. Stop
fails every pending read once and releases the core. There is no read backend
yet: every read fails `kIOReturnNotReady`, and compressed container bytes are
never served as raw disk bytes. `scripts/tests/driverkit-service-target.sh`
requires the sources in the dext target and one shared definition of the key.
Hosting the mount selectors in the user client, so their publish and remove
hooks create and terminate this child, is #467.
