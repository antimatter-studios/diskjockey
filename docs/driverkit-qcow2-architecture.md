# DriverKit block-device architecture for QCOW2/VHDX

Research date: 2026-05-29  
SDK: DriverKit 451 (Xcode 26), macOS 26.0 deployment target

---

## Executive summary

There are two viable paths for QCOW2/VHDX mounting:

| Path | Complexity | Status |
|---|---|---|
| **A — FSKit V2 `FSPathURLResource`** | Low — extend existing FSKit extensions | Available: macOS 26.0 target matches |
| **B — DriverKit `IOUserBlockStorageDevice`** | High — new dext, entitlement exception, async I/O dispatch | Full block-device semantics, MAS-compatible |

**Recommendation: ship Path A first.** The FSKit API became public in macOS 26.0 (same as the project's deployment target), requires no new entitlements beyond what the extensions already hold, and the Rust Qcow2 reader is already compiled into `libqcow2.a` and linked into the EXT4/NTFS extensions. Path B is documented below as the fallback if Apple rejects Path A at app review or if `FSPathURLResource` turns out not to be mountable via `DADiskMount` at runtime.

---

## Part 1: FSKit V2 path — the simpler option

### 1.1 What changed in macOS 26

`FSKitDefines.h` defines:

```c
// original API (macOS 15.4)
#define FSKIT_API_AVAILABILITY_V1 API_AVAILABLE(macos(15.4))

// macOS 26 API
#define FSKIT_API_AVAILABILITY_V2 API_AVAILABLE(macos(26.0))
```

`FSResource.h` marks `FSPathURLResource` and `FSGenericURLResource` as `FSKIT_API_AVAILABILITY_V2`. The project's `MACOSX_DEPLOYMENT_TARGET = 26.0`, so both are available.

### 1.2 FSPathURLResource shape

```objc
// FSResource.h (macOS 26.0+)
@interface FSPathURLResource : FSResource
@property (readonly, copy) NSURL *url;
- (instancetype)initWithURL:(NSURL *)URL writable:(BOOL)writable;
@property (readonly, getter=isWritable) BOOL writable;
@end
```

The FSKit daemon (`fskitd`) transports a security-scoped URL intact from the host app to the extension. The extension receives it in `probeResource:replyHandler:` and `loadResource:options:replyHandler:` as an `FSResource *` that can be cast to `FSPathURLResource *`.

### 1.3 Mount trigger

There is no public programmatic FSKit mount API in `FSClient.h` (which only lists installed extensions). The mount path uses `mount(8)` or `DADiskMount`:

```
mount -F -t ext4 file:///path/to/disk.qcow2 /Volumes/MyDisk
```

The existing `FSKitMountService.attach()` already calls DA for block devices and `hdiutil` for file-backed images. For QCOW2/VHDX the call changes to:

```swift
// Instead of hdiutil → /dev/diskN → DA
// Directly ask fskitd to activate the URL resource
// The mount path: "mount -F -t ext4 <url> <mountpoint>"
// ...handled by existing runShellAsAdmin / mount -F path
```

**Open question for first test:** does `mount -F -t ext4 file:///disk.qcow2 /Volumes/Foo` reach the FSKit extension with an `FSPathURLResource`, or does `mount(8)` reject a non-/dev path? If it rejects, the fallback is to call the FSKit XPC service directly (undocumented but the existing `mount -F` wrapper already does this on macOS 26).

### 1.4 Extension changes (EXT4 and NTFS)

**Info.plist** — declare `file:` URL support:

```xml
<key>FSSupportsGenericURLResources</key>
<false/>
<!-- FSPathURLResource is the right class; no scheme declaration needed -->
```

Note: `FSGenericURLResource` requires `FSSupportedSchemes`. `FSPathURLResource` does not — the system routes `file://` paths directly.

**EXT4FileSystem.swift** — dispatch by resource type:

```swift
func probeResource(
    _ resource: FSResource,
    replyHandler: @escaping (FSProbeResult?, Error?) -> Void
) {
    if let block = resource as? FSBlockDeviceResource {
        probeBlockDevice(block, replyHandler: replyHandler)
    } else if #available(macOS 26.0, *),
              let urlRes = resource as? FSPathURLResource {
        probeURLResource(urlRes, replyHandler: replyHandler)
    } else {
        replyHandler(.notRecognizedProbeResult, nil)
    }
}

@available(macOS 26.0, *)
private func probeURLResource(
    _ resource: FSPathURLResource,
    replyHandler: @escaping (FSProbeResult?, Error?) -> Void
) {
    let path = resource.url.path
    // Parse optional partition selector from fragment: file:///disk.qcow2#part=0
    let (imagePath, partIndex) = parseURLFragment(resource.url)

    // Open via existing Rust C ABI (already linked into libfs_ext4.a)
    guard let dev = qcow2_open(imagePath) else {
        replyHandler(.notRecognizedProbeResult, nil)
        return
    }
    defer { fs_core_device_close(dev) }

    let slice: OpaquePointer?
    if let idx = partIndex {
        slice = openPartitionSlice(dev, index: idx)
    } else {
        slice = dev
    }
    // Read first 1080 bytes, look for ext4 superblock magic 0xEF53 at offset 1080
    guard let magic = readMagic(slice) else { ... }
    ...
}
```

**Linking** — no change. `libqcow2.a` is already linked into the EXT4 extension via `OTHER_LDFLAGS = -lqcow2`, and `qcow2.h` is already in the bridging header.

### 1.5 Host app changes

`FSKitAttachController.detectFSType` already identifies QCOW2/VHDX and throws `"requires DriverKit"`. Replace the error with actual mount dispatch:

```swift
if detected == .qcow2 || detected == .vhdx {
    try await attachViaURLResource(imagePath: source, name: name, fsType: fsType)
    return
}

private func attachViaURLResource(
    imagePath: String,
    name: String,
    fsType: String
) async throws {
    let diskProbeResult = try await probePartitions(imagePath)
    for (i, part) in diskProbeResult.partitions.enumerated() {
        guard let fsType = fskitFSType(part.fsKind) else { continue }
        // Encode partition selector as URL fragment
        let url = "file://\(imagePath)#part=\(i)"
        try await runMountFSKit(url: url, fsType: fsType, mountName: "\(name)–p\(i)")
    }
}
```

---

## Part 2: DriverKit IOUserBlockStorageDevice — the robust fallback

Use this path if Path A fails app review or doesn't work at runtime. It is unambiguously correct: once the dext is running, the block device appears as `/dev/diskN`, diskarbitrationd probes it, and the existing DA → FSKit pipeline handles the rest with zero changes to the FSKit extensions.

### 2.1 IOUserBlockStorageDevice fundamentals

Header: `BlockStorageDeviceDriverKit.framework/Headers/IOUserBlockStorageDevice.iig`  
SDK: `DriverKit.platform/Developer/SDKs/DriverKit.sdk/` (version 451, arm64-driverkit)

`IOUserBlockStorageDevice` is an `IOService` subclass. Its protocol defines two groups of methods:

**Mandatory pure-virtual methods the dext must implement:**

```cpp
// Core I/O — the dext calls CompleteIO/Complete when done
virtual kern_return_t DoAsyncReadWrite(
    bool isRead,
    uint32_t requestID,
    uint64_t dmaAddr,
    uint64_t size,
    uint64_t lba,
    uint64_t numOfBlocks,
    IOUserStorageOptions options) = 0;

// Lifecycle
virtual kern_return_t DoAsyncEjectMedia(uint32_t requestID) = 0;
virtual kern_return_t DoAsyncSynchronize(uint32_t requestID, uint64_t lba, uint64_t numOfBlocks) = 0;

// Device metadata
virtual kern_return_t GetDeviceParams(struct DeviceParams *deviceParams) = 0;
virtual kern_return_t GetVendorString(struct DeviceString *vendor) = 0;
virtual kern_return_t GetProductString(struct DeviceString *product) = 0;
virtual kern_return_t GetRevisionString(struct DeviceString *revision) = 0;
virtual kern_return_t GetAdditionalInfoString(struct DeviceString *additionalInfo) = 0;
virtual kern_return_t ReportEjectability(bool *isEjectable) = 0;
virtual kern_return_t ReportRemovability(bool *isRemovable) = 0;
virtual kern_return_t ReportWriteProtection(bool *isWriteProtected) = 0;
```

**Completion callbacks the dext calls back into the framework:**

```cpp
// After DoAsyncReadWrite completes:
void CompleteIO(uint32_t requestID, uint64_t bytesTransferred, kern_return_t IOStatus)
    QUEUENAME(Completion);

// After DoAsyncEjectMedia / DoAsyncSynchronize / DoAsyncUnmap complete:
void Complete(uint32_t requestID, kern_return_t status) QUEUENAME(Completion);
```

**`DeviceParams` struct** — returned from `GetDeviceParams`:

```cpp
struct DeviceParams {
    uint64_t numOfBlocks;
    uint32_t blockSize;          // typically 512 or 4096
    uint32_t maxIOSize;
    uint32_t numOfOutstandingIOs;
    uint32_t maxNumOfUnmapRegions;
    uint32_t minSegmentAlignment;
    uint8_t  numOfAddressBits;
    bool     isUnmapSupported;
    bool     isFUASupported;
};
```

**`RegisterDext()`** must be called from `Start()` to hook the dext into the kernel block I/O stack. Without this call, no `/dev/diskN` node appears.

### 2.2 Virtual (software-only) device creation

For hardware drivers, `IOProviderClass` in the `IOKitPersonalities` plist is the class of the physical hardware node (e.g. `IOPCIDevice`, `IOUSBHostDevice`). For a software-only driver with no physical hardware, the Xcode Driver template uses:

```xml
<key>IOProviderClass</key>
<string>IOUserResources</string>
<key>IOResourceMatch</key>
<string>IOKit</string>
```

`IOUserResources` is a kernel singleton always present after IOKit initialises. `IOResourceMatch = "IOKit"` means "match when the IOKit resource is published", which happens at boot. This causes the dext to be launched **once at app install / first boot**, just like an audio dext.

**Problem:** we need one virtual block device per QCOW2 file, on demand. A single static personality that launches once is wrong for this use case.

**Solution: host-initiated device creation via IOUserClient**

The canonical pattern for demand-instantiated virtual devices:

1. The dext starts once (matching `IOUserResources`), initialises Rust, does nothing else.
2. The host app opens a `IOUserClient` connection to the dext via `IOServiceOpen`.
3. The host sends a `MountImage` command (selector 0) carrying the file path.
4. The dext calls `IOService::Create()` to instantiate a new `IOUserBlockStorageDevice` child node representing that file, then calls `RegisterDext()` on it.
5. The kernel publishes the child node → diskarbitrationd sees a new media → `/dev/diskN` appears.
6. The host watches for DA disk-appeared notifications, matches against the UUID it embedded in device strings, then calls `DADiskMount` to trigger the FSKit extension.
7. To detach: host sends `UnmountImage` command → dext calls `Terminate()` on the child node → kernel removes `/dev/diskN` → DA cleans up.

### 2.3 App ↔ dext IPC

DriverKit provides `IOUserClient` (same name as the kernel class, same `IOServiceOpen` API). Header: `DriverKit.framework/Headers/IOUserClient.iig`.

The dext side implements:

```cpp
class DJVirtualDiskUserClient : public IOUserClient {
public:
    virtual kern_return_t ExternalMethod(
        uint64_t selector,
        IOUserClientMethodArguments *arguments,
        const IOUserClientMethodDispatch *dispatch,
        OSObject *target,
        void *reference) LOCALONLY;
};
```

Selectors (define as enum in a shared header):

```cpp
enum DJVirtualDiskSelector : uint64_t {
    kDJSelectorMountImage   = 0,  // input: path string (structureInput)
    kDJSelectorUnmountImage = 1,  // input: deviceID (scalarInput[0])
    kDJSelectorListMounts   = 2,  // output: array of {deviceID, devNode} (structureOutput)
};
```

The host app side (Swift, unsandboxed via DiskJockeyAgent):

```swift
import IOKit

func connectToVirtualDiskDext() throws -> io_connect_t {
    let service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("DJVirtualDiskService")  // IOUserClass from dext Info.plist
    )
    guard service != IO_OBJECT_NULL else { throw DextError.serviceNotFound }
    var connection: io_connect_t = IO_OBJECT_NULL
    let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
    guard kr == KERN_SUCCESS else { throw DextError.openFailed(kr) }
    return connection
}

func mountQcow2(_ path: String, connection: io_connect_t) throws -> UInt64 {
    var deviceID: UInt64 = 0
    var outputCount: UInt32 = 1
    let pathData = path.data(using: .utf8)!
    try pathData.withUnsafeBytes { ptr in
        let kr = IOConnectCallMethod(
            connection,
            UInt32(DJVirtualDiskSelector.mountImage.rawValue),
            nil, 0,                             // scalar input
            ptr.baseAddress, UInt32(ptr.count), // struct input = path
            &deviceID, &outputCount,            // scalar output = deviceID
            nil, nil                            // struct output
        )
        guard kr == KERN_SUCCESS else { throw DextError.mountFailed(kr) }
    }
    return deviceID
}
```

**Entitlement for host app to open the user client:**

The dext's `IOKitPersonalities` entry needs:

```xml
<key>IOServiceDEXTEntitlements</key>
<array>
    <string>com.apple.developer.driverkit.userclient-access</string>
</array>
```

The host app (DiskJockeyAgent, unsandboxed) needs:

```xml
<key>com.apple.developer.driverkit.userclient-access</key>
<array>
    <string>com.antimatterstudios.diskjockey.virtualdisk</string>
</array>
```

### 2.4 How `DoAsyncReadWrite` calls Rust

`DoAsyncReadWrite` receives a DMA address (`dmaAddr`) and a size. In DriverKit, DMA addresses in user-space dexts refer to memory mapped via `IOMemoryDescriptor`. The pattern:

```cpp
kern_return_t DJVirtualDiskDevice::DoAsyncReadWrite(
    bool isRead,
    uint32_t requestID,
    uint64_t dmaAddr,
    uint64_t size,
    uint64_t lba,
    uint64_t numOfBlocks,
    IOUserStorageOptions options)
{
    uint64_t byteOffset = lba * ivars->blockSize;

    // Map the DMA buffer into our address space
    IOMemoryDescriptor *md = nullptr;
    // (framework allocates the memory descriptor from dmaAddr in newer SDKs;
    //  older pattern: use IOBufferMemoryDescriptor + map)

    uint8_t *buf = reinterpret_cast<uint8_t*>(dmaAddr);  // direct pointer in dext address space

    FsCoreErrorCode rc;
    if (isRead) {
        rc = fs_core_device_read_at(ivars->qcow2Dev, byteOffset, buf, (size_t)size);
    } else {
        rc = fs_core_device_write_at(ivars->qcow2Dev, byteOffset, buf, (size_t)size);
    }

    kern_return_t status = (rc == FS_CORE_OK) ? kIOReturnSuccess : kIOReturnIOError;
    CompleteIO(requestID, (rc == FS_CORE_OK) ? size : 0, status);
    return kIOReturnSuccess;  // return value indicates if we accepted the request, not IO success
}
```

Note: `dmaAddr` in DriverKit user-space is a pointer mapped into the dext process virtual address space; it is not a physical DMA address. The kernel handles the actual DMA into/from the buffer.

### 2.5 Rust static library linking in a dext

A dext is a Mach-O executable (product type `com.apple.product-type.driver-extension`, `.dext` bundle). It links against static `.a` archives exactly like an app extension.

**Build settings mirror** the existing FSKit extension pattern:

```
SDKROOT = driverkit               # ← different from FSKit (macosx)
SUPPORTED_PLATFORMS = driverkit
PRODUCT_TYPE = com.apple.product-type.driver-extension
ARCHS = arm64                     # arm64 only per project convention
ONLY_ACTIVE_ARCH = YES
LIBRARY_SEARCH_PATHS = $(SRCROOT)/lib/img_qcow2 $(SRCROOT)/lib/img_vhdx
OTHER_LDFLAGS = -lqcow2 -lvhdx -lSystem
HEADER_SEARCH_PATHS = $(SRCROOT)/lib/img_qcow2/include $(SRCROOT)/lib/img_vhdx/include
```

**Critical difference from app/appex:** the DriverKit SDK uses a stripped-down libc. Missing:

- `pthread_*` — no pthreads; use DriverKit dispatch queues
- `mach_*` — limited Mach API
- `malloc`/`free` — present but limited
- No `NSObject`, no Objective-C runtime

**Rust library requirements for dext linking:**

The `libqcow2.a` / `libvhdx.a` static libraries **should link cleanly** because:
- They expose a pure C ABI (`extern "C"`)
- They use `core`/`alloc`, not `std`, for memory (the Rust stdlib has `libc` dep but that links fine)
- No thread-locals that Rust `std` creates at thread-spawn time (the Rust global allocator uses `malloc` which exists in DriverKit libc)

**Potential issues to test:**

1. **Panic handler:** Rust's default panic handler calls `abort()` (which exists in DriverKit libc) — fine.
2. **Global allocator:** `malloc`/`free` are available. Fine.
3. **TLS (thread-local storage):** Rust `std` uses TLS for `errno`, error messages etc. DriverKit supports TLS in dext executables. The `fs_core_last_error_message()` function uses a thread-local. Should work but verify at link time.
4. **`libunwind`:** DriverKit bundles a stripped unwind library. Rust panics use `libunwind` for stack traces; with `panic = "abort"` in Cargo.toml this path is never taken.

**Recommended Cargo.toml setting for the Rust library when built for dext:**

```toml
[profile.release]
panic = "abort"
```

This eliminates the `libunwind` dependency entirely. The libraries are already compiled; if they were built with `panic = "abort"` (check `vendor/rust-img-qcow2/Cargo.toml`) no change is needed.

### 2.6 Entitlements

**Dext** (`DiskJockeyVirtualDisk.dext.entitlements`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <!-- Base DriverKit entitlement — required for any dext -->
    <key>com.apple.developer.driverkit</key>
    <true/>

    <!-- Block storage family — required to use BlockStorageDeviceDriverKit -->
    <!-- This entitlement must be requested via the entitlement exception form -->
    <key>com.apple.developer.driverkit.family.storage</key>
    <true/>

    <!-- Allow the host app to open our IOUserClient -->
    <key>com.apple.developer.driverkit.allow-any-userclient-access</key>
    <true/>
</dict>
</plist>
```

**Host app / DiskJockeyAgent** (`DiskJockeyAgent.entitlements` addition):

```xml
<!-- To call IOServiceOpen on the dext's user client -->
<key>com.apple.developer.driverkit.userclient-access</key>
<array>
    <string>com.antimatterstudios.diskjockey.virtualdisk</string>
</array>
```

**Entitlement request process:**

- `com.apple.developer.driverkit` — available without exception, part of the standard DriverKit capability request.
- `com.apple.developer.driverkit.family.storage` — **requires entitlement exception**. Submit through the Apple Developer entitlement exception form. State the use case: "virtual block device for mounting QCOW2/VHDX disk images without a kernel extension". Audio has `com.apple.developer.driverkit.family.audio` as precedent. Storage is analogous.

Note: `com.apple.developer.driverkit.transport.usb` / `.hid` / `.builtin` are NOT needed — those are transport-layer entitlements for hardware drivers. A software-only virtual device needs only `family.storage`.

### 2.7 dext Info.plist

```xml
<key>CFBundleIdentifier</key>
<string>com.antimatterstudios.diskjockey.virtualdisk</string>

<key>IOKitPersonalities</key>
<dict>
    <!-- Personality 1: the manager service that the host app opens -->
    <key>DJVirtualDiskManager</key>
    <dict>
        <!-- Match as soon as IOKit is up (software-only, no hardware) -->
        <key>IOProviderClass</key>
        <string>IOUserResources</string>
        <key>IOResourceMatch</key>
        <string>IOKit</string>

        <!-- Which DriverKit class implements this personality -->
        <key>IOUserClass</key>
        <string>DJVirtualDiskService</string>

        <!-- Kernel-side IOService wrapper -->
        <key>IOClass</key>
        <string>IOUserService</string>

        <!-- Server name for the IOUserServer that hosts this dext -->
        <key>IOUserServerName</key>
        <string>com.antimatterstudios.diskjockey.virtualdisk</string>

        <!-- Required entitlements for any process that opens our UserClient -->
        <key>IOServiceDEXTEntitlements</key>
        <array>
            <string>com.apple.developer.driverkit.userclient-access</string>
        </array>

        <!-- Prevents another driver from stealing this match -->
        <key>IOMatchCategory</key>
        <string>com.antimatterstudios.diskjockey.virtualdisk</string>

        <key>CFBundleIdentifierKernel</key>
        <string>com.apple.kpi.iokit</string>
    </dict>
</dict>

<key>OSBundleUsageDescription</key>
<string>DiskJockey virtual disk driver provides block device access to QCOW2 and VHDX disk image files.</string>
```

### 2.8 Full mount flow (DriverKit path)

```
User clicks "Mount" on disk.qcow2
          │
          ▼
DiskJockeyApp (sandboxed)
  Calls XPC → DiskJockeyAgent (unsandboxed)
          │
          ▼
DiskJockeyAgent
  IOServiceOpen("DJVirtualDiskService") → io_connect_t
  IOConnectCallMethod(kDJSelectorMountImage, path="disk.qcow2")
          │
          ▼ (IPC to dext)
DJVirtualDiskService (dext)
  ExternalMethod(kDJSelectorMountImage)
    qcow2_open("/path/to/disk.qcow2")  → FsCoreDevice*
    IOService::Create(provider, "DJVirtualDiskDeviceProps", &child)
    child->RegisterDext()          ← hooks into IOBlockStorageDriver
    return deviceID (UInt64)
          │
          ▼ (kernel side)
IOBlockStorageDriver stack
  publishes /dev/diskN node in IOKit registry
          │
          ▼
diskarbitrationd
  sees new media, probes it, dispatches FSKit probe
          │
          ▼
DiskJockeyAgent
  DA disk-appeared callback
  Match: device's IOMedia properties contain our UUID
  DADiskMount(disk, "/Volumes/MyDisk", ...)
          │
          ▼
fskitd → DiskJockeyEXT4 / DiskJockeyNTFS
  probeResource(FSBlockDeviceResource)
  loadResource → FSVolume appears in Finder
```

**Unmount flow:**

```
User clicks "Eject"
  NSWorkspace.unmountAndEjectDevice(at: mountPoint)
    → DADiskUnmount → fskitd → extension unloadResource
    → diskarbitrationd → disk disappeared
  DiskJockeyAgent:
    IOConnectCallMethod(kDJSelectorUnmountImage, deviceID)
      → dext Terminate() child IOService → /dev/diskN removed
```

### 2.9 Multi-partition QCOW2

One dext instance per partition slice. The host app:

1. Calls `diskprobe` (already implemented) to get partition layout.
2. For each ext4/NTFS partition, sends a separate `MountImage` command with path and partition offset/length embedded in a struct.
3. The dext opens a slice via `fs_core_device_slice_ro/rw(qcow2Dev, partStart, partLength)` and exposes that slice as a separate `IOUserBlockStorageDevice` child.
4. Each child gets a unique UUID in its device strings (used by the DA callback to identify which volume appeared).

---

## Part 3: New Xcode targets

### Path A (FSKit URL resource) — zero new targets

Changes are confined to:
- `DiskJockeyEXT4/EXT4FileSystem.swift` — add `FSPathURLResource` dispatch branch
- `DiskJockeyNTFS/NTFSFileSystem.swift` — same
- `DiskJockeyApplication/Services/FSKitMountService.swift` — replace the "QCOW2 not supported" error with a URL mount dispatch

### Path B (DriverKit) — two new targets

| Target | Type | Notes |
|---|---|---|
| `DiskJockeyVirtualDisk` | Driver Extension (`.dext`) | C++ + Rust C ABI; DriverKit SDK |
| _(no new helper needed)_ | — | DiskJockeyAgent (already unsandboxed) handles `IOServiceOpen` |

The dext is embedded in the main app bundle under `Contents/Library/SystemExtensions/`. Activation uses `SystemExtensions.framework` (`OSSystemExtensionRequest.activationRequest`).

---

## Part 4: Rust linking — specific notes for dext build

The DriverKit SDK is a separate build target from macOS (`SDKROOT = driverkit`). Rust `.a` files compiled for `aarch64-apple-macosx` (the current output from `cargo build --target aarch64-apple-darwin`) **will NOT link cleanly** into a dext because the dext object files carry the `aarch64-apple-driverkit` platform tag.

**Fix:** add a `aarch64-apple-driverkit` target to Cargo:

```toml
# In .cargo/config.toml or via CARGO_BUILD_TARGET env var:
[target.aarch64-apple-driverkit]
linker = "clang"
ar = "ar"
rustflags = ["-C", "target-os=driverkit"]
```

Or, more practically: compile the Rust code as `aarch64-apple-macosx` (same machine code) and use a linker script to strip the platform tag, since the machine code is identical. The difference is only in LC_BUILD_VERSION. This is the pragmatic approach — Apple's Xcode does similar platform-tag rewriting for XCFrameworks.

**Alternative**: expose the Rust I/O through a thin C-callable wrapper that the dext calls via a dispatch queue, isolating Rust TLS assumptions from the dext's threading model.

---

## Part 5: Implementation order

1. **Test Path A first** (1–2 days):
   - Add `FSPathURLResource` cast in `probeResource` in EXT4FileSystem.swift
   - Try `mount -F -t ext4 "file:///path/to/disk.qcow2" /tmp/test` from Terminal
   - If fskitd delivers the resource as `FSPathURLResource` and the extension can open the file → ship Path A

2. **If Path A fails or is rejected at review**, proceed to Path B:
   - Request `com.apple.developer.driverkit.family.storage` exception from Apple
   - Create `DiskJockeyVirtualDisk` dext target
   - Implement `DJVirtualDiskService` (manager) and `DJVirtualDiskDevice` (per-file block device)
   - Wire `DiskJockeyAgent` to call `IOServiceOpen` / `IOConnectCallMethod`
   - Add DA disk-appeared callback in agent → `DADiskMount`
   - Add `OSSystemExtensionRequest` activation in app UI

---

## Appendix: key header locations

| Header | Path |
|---|---|
| `IOUserBlockStorageDevice.iig` | `.../DriverKit.sdk/.../BlockStorageDeviceDriverKit.framework/Headers/` |
| `IOUserClient.iig` | `.../DriverKit.sdk/.../DriverKit.framework/Headers/` |
| `IOService.iig` | `.../DriverKit.sdk/.../DriverKit.framework/Headers/` |
| `IOKitKeys.h` | `.../DriverKit.sdk/.../DriverKit.framework/Headers/` |
| `FSResource.h` | `.../MacOSX.sdk/System/Library/Frameworks/FSKit.framework/Versions/A/Headers/` |
| `FSKitDefines.h` | same — confirms V2 = macOS 26.0 |
| `FSClient.h` | same — confirms no programmatic mount API |
| `qcow2.h` | `$(SRCROOT)/lib/img_qcow2/include/` |
| `fs_core.h` | `$(SRCROOT)/lib/fs_ext4/include/` |

## Appendix: entitlement key constants (from IOKitKeys.h)

```c
// Base DriverKit entitlement
#define kIODriverKitEntitlementKey "com.apple.developer.driverkit"

// App needs this to call IOServiceOpen on a dext's user client
#define kIODriverKitUserClientEntitlementsKey "com.apple.developer.driverkit.userclient-access"

// Dext grants this to allow any app to open its user client
#define kIODriverKitUserClientEntitlementAllowAnyKey
    "com.apple.developer.driverkit.allow-any-userclient-access"

// Family entitlements — storage not in IOKitKeys.h (it's in the entitlement exception DB)
// Precedent from HID family:
#define kIODriverKitHIDFamilyDeviceEntitlementKey "com.apple.developer.driverkit.family.hid.device"
// Analogous storage entitlement (unconfirmed name, verify with Apple):
// "com.apple.developer.driverkit.family.storage"
```
