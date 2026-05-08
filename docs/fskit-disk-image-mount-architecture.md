# FSKit + disk-image mount architecture

Research notes on how to wire `am-img-qcow2` (and future `am-img-vhd`,
`am-img-vmdk`, …) into FSKit so a user can click a `.qcow2` file in
DiskJockey and see Finder volumes appear.

Source: FSKit framework headers in
`/Applications/Xcode.app/.../MacOSX.sdk/System/Library/Frameworks/FSKit.framework/Versions/A/Headers/`.

## What was the blocker

The existing `DiskJockeyEXT4` / `DiskJockeyNTFS` modules cast every
incoming `FSResource` to `FSBlockDeviceResource` and reject anything
else with `EINVAL`. `FSBlockDeviceResource` is bound to an `IOMedia`
node — a kernel block device. A `.qcow2` file isn't a block device,
so this path never fires.

Earlier I assumed the only way out was a kernel extension or
materialising the qcow2 to a raw `.img`. **Wrong.**

## The actual answer: `FSPathURLResource`

FSKit defines three concrete `FSResource` subclasses:

| Class | Backed by | Constructible from app code? |
|---|---|---|
| `FSBlockDeviceResource` | `IOMedia` (kernel) | only via system mount of a `/dev/disk*` path |
| `FSPathURLResource` | a `file://` URL (a regular file or directory) | **yes** — `init(URL:writable:)` is public |
| `FSGenericURLResource` | any URL scheme (`ssh://`, `rsh://`, etc.) | yes — `init(URL:)`; declare `FSSupportedSchemes` in Info.plist |

**`FSPathURLResource` is the right one for image-file mounts.** It
carries a URL (security-scoped if the app uses the file picker), FSKit
transports it intact to the extension, and the extension reads the
underlying file via standard file I/O. No `IOMedia`, no kext, no
hdiutil materialisation.

Header doc says explicitly:

> Some resources … come in proxy and non-proxy variants. … For
> example, a resource based on a `file://` URL might initialize when
> a person uses the "Connect to server" command in the macOS Finder.

## What's available in v1 (current macOS)

| Class | Availability | Purpose |
|---|---|---|
| `FSUnaryFileSystem` | **v1 (now)** | one-resource → one-volume. What our existing modules use. |
| `FSFileSystem` | **v2 (FSKIT_API_UNAVAILABLE_V1)** | one-resource → many-volumes. Not available in current macOS. |

So today: **one mount per FSResource → one FSVolume**. A single qcow2
with three partitions can't be "all volumes from one mount" until
`FSFileSystem` ships. Today's path is multiple sequential mounts, one
per partition.

## Implementation architecture

Two design choices.

### Option α — one FSKit module per filesystem, URL-aware

Existing pattern, extended:

- `DiskJockeyEXT4` already accepts `FSBlockDeviceResource`. Extend its
  `probeResource` / `loadResource` to **also** accept
  `FSPathURLResource`.
- When given a URL, open the URL's path through the Rust qcow2 reader
  (`qcow2_open` from `am-img-qcow2`), pick the ext4 partition, serve
  it.
- Multi-partition qcow2: the host app does N mounts, one per
  partition, each with a URL that carries the partition selector.

URL format proposal — encode the partition selector in the fragment
so it's transparent to the file:// scheme:

```
file:///path/to/disk.qcow2#part=2
```

Module parses the fragment, calls `partitions_open_slice(qcow2,
2)` (from `am-partitions`), drives ext4 against that slice.

For whole-disk-FS qcow2 (no partition table), the URL is plain
`file:///disk.qcow2` and the module mounts the whole virtual disk as
ext4.

**Pros**: minimal new code, reuses existing per-FS modules, multi-FS
support comes for free (one URL goes to ext4 module, another to ntfs
module, picked by the user or by sniff).

**Cons**: the host app still has to dispatch — pick which FSKit module
to invoke per partition based on FS sniff. That's host-side work
that already exists in `am-partitions`, just needs Swift wiring.

### Option β — separate `DiskJockeyContainer` module

A new FSKit module that accepts `FSPathURLResource` for `.qcow2` /
`.vhd` / `.vmdk` files. Internally:

- Opens the container file.
- Probes partitions.
- Sniffs FS on each.
- Returns a single FSVolume that exposes partitions as folders;
  each folder is the partition's filesystem (the container module
  embeds a copy of every fs driver).

**Pros**: one mount, one Finder volume for the whole qcow2, all
partitions visible inside.

**Cons**: not the SD-card semantics the user asked for (they wanted
each partition as its own Finder volume); container module has to
embed every fs driver.

### Recommended path

**Go with Option α**. Matches the user's stated UX preference
("inserting an SD card auto-mounts every partition as its own
volume"), reuses existing per-FS modules with minimal changes, scales
naturally to VHD/VMDK/etc. once those reader crates exist.

## Concrete change set (Option α)

### Per FSKit module (DiskJockeyEXT4 first, then NTFS)

1. **Info.plist** — declare URL scheme support:

   ```xml
   <key>FSSupportedSchemes</key>
   <array>
     <string>file</string>
   </array>
   ```

2. **EXT4FileSystem.swift** — extend `probeResource` and
   `loadResource` to dispatch by resource type:

   ```swift
   func probeResource(resource: FSResource, replyHandler: ...) {
       if let blockDevice = resource as? FSBlockDeviceResource {
           probeBlockDevice(blockDevice, replyHandler)
           return
       }
       if let url = resource as? FSPathURLResource {
           probeURL(url, replyHandler)
           return
       }
       replyHandler(.notRecognized, nil)
   }

   private func probeURL(
       _ resource: FSPathURLResource,
       _ replyHandler: ...
   ) {
       // Parse URL — file:///disk.qcow2[#part=N]
       let path = resource.url.path
       let partIdx = parsePartitionFragment(resource.url.fragment)
       // Open via Rust C ABI.
       let qcow2 = qcow2_open(path)
       // If partIdx given, slice via partitions_open_slice.
       // Read first 1024 bytes off the slice, look for ext4 superblock magic 0xEF53.
       ...
   }
   ```

3. **Bridging header** — pull in `fs_core.h`, `qcow2.h`,
   `partitions.h`. Link the `am-fs-core`, `am-img-qcow2`,
   `am-partitions` static libraries.

### Host app (DiskJockeyApplication)

1. **`Qcow2Service.swift`** (new) — Swift wrapper over the Rust C ABI:

   ```swift
   final class Qcow2Service {
       func inspect(path: URL) -> Qcow2Inventory { ... }
   }

   struct Qcow2Inventory {
       let virtualSize: UInt64
       let partitions: [PartitionInfo]
   }

   struct PartitionInfo {
       let index: Int
       let start: UInt64
       let length: UInt64
       let fsKind: FsKind  // ext4 / ntfs / fat32 / unknown / ...
       let label: String?
   }
   ```

2. **`FSKitMountService.swift`** — new method:

   ```swift
   func attachContainer(qcow2Path: String, name: String) async throws {
       let inv = qcow2Service.inspect(URL(fileURLWithPath: qcow2Path))
       for (i, part) in inv.partitions.enumerated() {
           let url = "file://\(qcow2Path)#part=\(i)"
           let fsType = mapFsKindToFSKitType(part.fsKind) // "ext4" / "ntfs"
           guard let fsType else { continue }  // skip unknown
           try await attach(
               imagePath: url,
               name: "\(name) — part\(i)",
               fsType: fsType
           )
       }
   }
   ```

   And the existing `attach` accepts a URL string instead of always a
   filesystem path. The system mount path for FSKit hands the URL
   into `FSPathURLResource`.

3. **UI** — add a "Mount qcow2" button to the existing
   `AttachedDiskDetailView` (or wherever raw disks are listed). On
   click, opens NSOpenPanel for `.qcow2` files, calls
   `attachContainer`.

## Open questions for hands-on testing

1. Does `mount -F -t ext4 file:///disk.qcow2#part=0 /mnt` work, or
   does the system's `mount(8)` reject URL-as-source? If yes, the
   existing `runShellAsAdmin` flow handles dispatch. If no, we need
   the programmatic FSKit mount API (which exists but I haven't
   located the entry point yet — likely `FSResource` needs to be
   registered via XPC to the user's `fskitd` daemon).

2. Is `FSPathURLResource(URL:writable:)` callable from a
   non-extension process (the host app) or only from an FSKit
   extension's reply path? The header gives no obvious restriction,
   but FSKit may require the resource to come through a system
   intermediary.

3. Does the entitlement `com.apple.developer.fskit.fsmodule` (or
   similar) need broadening for URL-scheme support, on top of the
   block-device entitlement the existing modules use?

4. Multi-mount sequencing: if we issue three concurrent
   `mount -F` calls for three partitions, does FSKit serialise them
   per-extension, or do we get races on the shared `loadResource`
   path? The current code does keep a per-resource map, so probably
   fine — but worth verifying under load.

## Trade-offs and roadmap

- **Today (FSKit v1)**: Option α delivers the SD-card UX (one volume
  per partition) at the cost of N sequential mounts per qcow2. Good
  enough.
- **macOS that ships FSKit v2 (`FSFileSystem`)**: collapse to one
  mount per qcow2, multiple FSVolumes returned. UX identical;
  internal plumbing simpler.
- **VHD / VHDX / VMDK / VDI**: same path. Each `am-img-<x>` crate
  exposes a `<x>_open(path)` C ABI; the FSKit module's URL-handling
  branch dispatches based on file extension or magic.

## Why this isn't done now

Implementation needs hands-on testing per CLAUDE.md — the open
questions above are empirical. The Rust + C-ABI side of every layer
exists today; the Swift dispatcher and Info.plist updates are
mechanical once we know whether `mount -F` accepts URLs and which
entitlement permits URL-resource dispatch.

This doc is the blueprint. Picking it up takes a focused session at
the keyboard, not an autonomous burst.
