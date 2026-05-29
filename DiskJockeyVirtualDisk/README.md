# DiskJockeyVirtualDisk

DriverKit extension (`.dext`) that presents QCOW2 and VHDX image files as
virtual block devices (`/dev/diskN`). This is the Path B fallback if
`FSPathURLResource` mounting (Path A) is rejected at App Review or doesn't
work at runtime.

## Entitlement exception required

`com.apple.developer.driverkit.family.storage` is a restricted entitlement.
Before this dext can load, you must:

1. Request an exception at <https://developer.apple.com/contact/request/driverkit-entitlement/>
2. Justification: "Virtual block device to mount QCOW2/VHDX disk images as
   `/dev/diskN` nodes via `IOUserBlockStorageDevice`. No physical hardware."
3. Once granted, add the capability to the provisioning profile in the
   Apple Developer portal and re-provision.

## Adding as an Xcode target

1. **File → New → Target → Driver Extension**
2. Product name: `DiskJockeyVirtualDisk`; bundle ID: `com.antimatterstudios.diskjockey.virtualdisk`
3. Build settings:
   - `SDKROOT = driverkit`
   - `SUPPORTED_PLATFORMS = driverkit`
   - `ARCHS = arm64`
   - `ONLY_ACTIVE_ARCH = YES`
   - `LIBRARY_SEARCH_PATHS = $(SRCROOT)/lib/img_qcow2 $(SRCROOT)/lib/img_vhdx $(SRCROOT)/lib/fs_core`
   - `OTHER_LDFLAGS = -lam_img_qcow2 -lam_img_vhdx -lam_fs_core`
   - `HEADER_SEARCH_PATHS = $(SRCROOT)/vendor/rust-img-qcow2/include $(SRCROOT)/vendor/rust-img-vhdx/include $(SRCROOT)/vendor/rust-fs-core/include`
4. Replace the generated `Info.plist` with the one in this directory.
5. Replace the generated entitlements file with `DiskJockeyVirtualDisk.entitlements`.
6. Add all `.cpp` source files from this directory to the target.
7. Embed the `.dext` bundle in DiskJockeyApplication under
   `Contents/Library/SystemExtensions/`.

## Rust library notes

The `.a` files (`libam_img_qcow2.a`, `libam_img_vhdx.a`, `libam_fs_core.a`)
are compiled for `aarch64-apple-darwin`. They must be recompiled for the
DriverKit platform tag (`aarch64-apple-driverkit`) or linked with a linker
script that strips `LC_BUILD_VERSION`. Pragmatic approach: use the same arm64
machine code and override the platform tag at link time. See
`docs/driverkit-qcow2-architecture.md` Section 4 for details.
