# v1 Deferred Features

Features cut from the v1 MAS submission. Each section records what was built, why it was deferred, what's needed to ship it, and where the code lives.

---

## 1. Disk image mounting (QCOW2, VHDX, VMDK)

**Status in v1:** Inspector shows "Mounting coming in a future update" for QCOW2, VHDX, VMDK. Raw `.img` / VHD / VMDK images that carry a single EXT4 or NTFS partition can already be mounted via `hdiutil attach` + FSKit — that path is live.

**Why deferred:** Mounting QCOW2/VHDX requires either a DriverKit virtual block device (entitlement exception) or the FSKit v2 `FSPathURLResource` API (macOS 26.0+, available at our deployment target but untested at app review). Neither path can be validated without SIP disabled or a signed DriverKit entitlement.

**Two viable paths:**

| Path | What's needed | Notes |
|------|--------------|-------|
| A — FSKit V2 `FSPathURLResource` | No new entitlements; macOS 26+ only | Described in `docs/driverkit-qcow2-architecture.md` §1. Try this first after v1 ships. |
| B — DriverKit `IOUserBlockStorageDevice` | `com.apple.developer.driverkit.family.storage` + `com.apple.developer.driverkit.allow-any-userclient-access` via entitlement request | Described in `docs/driverkit-qcow2-architecture.md` §2. Apply after the app has a live MAS presence. |

**Code:**
- `DiskJockeyVirtualDisk/` — DriverKit dext (Path B), compiles and links, on branch `feat/qcow2-mount-via-fskit`
- `DiskJockeyApplication/Views/DiskImageInspectorView.swift` — `isMountableContainer` gate, `upcomingMountNotice` view
- `DiskJockeyApplication/Services/FSKitMountService.swift` — `attachAllPartitions()` throws for unsupported containers

**To resume:** Start with FSKit Path A (no entitlement needed). If that fails at review, file the DriverKit entitlement request from App Store Connect. The dext is ready.

---

## 2. Format disk (EXT4 / NTFS)

**Status in v1:** `RawDiskDetailView` shows "Formatting coming in a future update". The format buttons and all `osascript` / `Process` code have been removed.

**Why deferred:** The MAS sandbox forbids spawning privileged helper processes from the main app. The original implementation used `osascript do shell script ... with administrator privileges` — near-certain rejection. The correct v2 path routes through the DiskJockey agent (LaunchAgent, runs outside sandbox).

**What's built:**
- Rust `fs_ext4::mkfs::format_filesystem` — in `vendor/rust-fs-ext4`, compiled into `lib/fs_ext4/libfs_ext4.a`
- Rust `fs_ntfs::mkfs::format_filesystem` — in `vendor/rust-fs-ntfs`, compiled into `lib/fs_ntfs/libfs_ntfs.a`
- FSKit `startFormat` hook — wired in `DiskJockeyEXT4Module` and `DiskJockeyNTFSModule`
- `docs/fskit-format-pipeline.md` — full pipeline description (now outdated on the UI path; keep the FSKit/Rust wiring section)

**What's needed for v2:**
1. Add a `formatDisk(bsdName:fsType:)` method to `DJAgentProtocol` + `AgentImpl`
2. Agent calls `/usr/sbin/diskutil eraseDisk <fs> <name> GPT <dev>` (whole) or `eraseVolume` (slice) — agent runs as the user outside the sandbox, so no admin prompt is needed for the user's own drives
3. `RawDiskDetailView` calls agent via `DJAgentClient`, shows progress
4. For internal/non-user-owned disks, agent may still need `AuthorizationExecuteWithPrivileges` or a separate privileged helper — evaluate at that point

**To resume:** Branch from `main`, extend `DJAgentProtocol`, implement in `AgentImpl`, rewire `RawDiskDetailView`.

---

## 3. Partition disk

**Status in v1:** "Partition…" button was never wired up and has been removed along with the format actions.

**Why deferred:** Same sandbox / osascript issue as formatting. Also requires UX design for partition count, sizes, and filesystem assignment.

**What's needed for v2:** Agent-side `diskutil partitionDisk` call. UX TBD — likely a sheet with a partition map editor.

---

## 4. DriverKit entitlement request

**Status:** Not filed. Apple requires a special request through App Store Connect to use `com.apple.developer.driverkit.family.storage`.

**When to file:** After v1 is live on the MAS — a live app URL and product page make the request credible. Without them, Apple's review is harder.

**What to request:**
- `com.apple.developer.driverkit.family.storage` — Block Storage Device family
- `com.apple.developer.driverkit.allow-any-userclient-access` — UserClient Access

**Where to apply:** App Store Connect → App → Capabilities → DriverKit → request entitlement. No public URL before the app exists.
