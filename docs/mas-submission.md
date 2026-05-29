# Mac App Store Submission

Living document. Fill in blanks before submission. Sections marked **TODO** need decisions.

---

## App Identity

| Field | Value |
|-------|-------|
| App name | DiskJockey |
| Bundle ID | `com.antimatterstudios.diskjockey` |
| Version | 1.0 |
| Build | 1 |
| Primary language | English |
| Team | Antimatter Studios (`43UMKXZ8P4`) |
| Min macOS | 15.0 (Sequoia) |
| Category | Utilities |
| Secondary category | Productivity |

---

## App Store Connect Listing

### Subtitle (30 chars max)
`EXT4, NTFS & network drives`

### Description (4000 chars max)

DiskJockey expands what your Mac can do with drives — letting you read and write Linux and Windows filesystems, and connect cloud and network storage, all without kernel extensions or third-party drivers.

Built on Apple's FSKit framework, DiskJockey works natively with macOS. No kexts. No kernel patches. No reboots.

**Linux & Windows Filesystems**
Mount EXT4 and NTFS drives with full read and write support. Plug in a drive formatted on Linux or Windows and it appears in Finder just like any other volume.

**Cloud & Network Drives**
Connect Google Drive, Dropbox, OneDrive, and other cloud storage directly through macOS File Provider. Access your files from any app on your Mac without keeping a browser tab open.

**Disk Image Inspector**
Drop a disk image onto DiskJockey to inspect it. See the container format, partition table, and filesystem type for every partition — whether it's a raw image, QCOW2, VHDX, or VMDK. Disk image mounting is coming in a future update.

**Why DiskJockey?**
macOS natively supports a handful of filesystems. If you work with Linux servers, run Windows VMs, or collaborate across platforms, you've likely hit the wall. DiskJockey removes it — giving your Mac the same flexibility you'd expect on any other operating system.

No administrator password required for everyday use. Sandboxed for your security.

### Keywords (100 chars max, comma-separated)
`ext4,ntfs,linux,filesystem,mount,disk,partition,cloud,network,drive,format,windows,fskit`

### GitHub
`https://github.com/antimatter-studios/diskjockey`

### Support URL
`https://www.antimatter-studios.com/diskjockey/support`

### Marketing URL
`https://www.antimatter-studios.com/diskjockey`

### Privacy Policy URL
`https://www.antimatter-studios.com/diskjockey/privacy` — see [privacy-policy.md](privacy-policy.md) for content

---

## Pricing

Paid — $1.99 (Tier 1)

---

## Screenshots

macOS requires **at least one** screenshot at exactly **1280×800** or **1440×900** (2x = 2560×1600 or 2880×1800).

Suggested shots:
1. Main window showing a mounted EXT4 drive
2. Disk image inspector (partition map view)
3. NTFS drive mounted, browsing files in Finder
4. **TODO** — any others?

---

## App Review Information

### Demo account
Not applicable (no login).

### Notes for reviewer
**TODO** — explain FSKit usage, that the app requires a physical or virtual Linux/Windows drive to demonstrate full functionality. Offer a test image if Apple requests one.

### Contact info
Christopher Thomas, Antimatter Studios — +49 151 61481184 — chris.thomas@antimatter-studios.com

---

## Entitlements & Capabilities (to verify in App Store Connect)

| Entitlement | Status | Notes |
|-------------|--------|-------|
| `com.apple.security.app-sandbox` | ✅ | all targets |
| `com.apple.developer.fskit.fsmodule` | **TODO: confirm self-service** | EXT4 + NTFS extensions |
| `com.apple.security.files.user-selected.read-write` | ✅ | main app |
| `com.apple.security.device.usb` | ✅ `NSUSBUsageDescription` added | main app |
| `com.apple.security.network.client` + `.server` | ✅ justified | main app: OAuth loopback listener (NWConnection). FileProvider: cloud sync. |
| `com.apple.security.temporary-exception.mach-lookup.global-name` | ✅ scoped | main app only (`diskjockey.agent`). FileProvider stale `xpc-bridge` removed. |
| `com.apple.developer.driverkit.family.storage` | ❌ not in v1 | deferred to v2 |

---

## Pre-Submission Checklist

### Code
- [x] App icon — all sizes filled
- [x] `PrivacyInfo.xcprivacy` added to app target
- [x] `NSUSBUsageDescription` added to `Info.plist`
- [x] `osascript` privilege escalation removed (FSKitMountService + RawDiskDetailView)
- [x] Temporary exception mach entitlements — scoped to main app agent only; FileProvider `xpc-bridge` removed
- [x] Network entitlements — justified (OAuth loopback in main app; cloud sync in FileProvider)
- [ ] `com.apple.developer.fskit.fsmodule` — confirm available in App Store Connect without special request
- [ ] Build passes `xcodebuild archive` cleanly (arm64 only)
- [ ] Build passes `xcrun altool` / Xcode Organizer validation with no errors

### App Store Connect
- [ ] App record created in App Store Connect
- [ ] Bundle ID registered
- [ ] App name reserved
- [ ] All listing fields filled (description, subtitle, keywords)
- [ ] Screenshots uploaded (1280×800 or 1440×900)
- [ ] Privacy policy URL live and accessible
- [ ] Support URL live and accessible
- [ ] Age rating questionnaire completed
- [ ] Export compliance answered (does app use encryption? Rust/TLS?)
- [ ] Pricing set
- [ ] Build uploaded and selected for review

### Testing
- [ ] Clean install test on a separate Mac or user account
- [ ] EXT4 mount/unmount works end-to-end
- [ ] NTFS mount/unmount works end-to-end
- [ ] Disk image inspector works for QCOW2 / VHDX / raw
- [ ] File Provider works without desktop app running
- [ ] App launches cleanly with no drives attached

---

## Export Compliance

**TODO** — Does the app use encryption?
- Rust stdlib uses TLS for network — but is any network code actually reachable?
- If yes: need to answer export compliance questions in App Store Connect (likely qualifies for standard exemption)

---

## Post-Rejection Plan

If rejected, likely reasons in priority order:
1. `osascript` admin escalation (fix: remove the code path)
2. Temporary exception entitlements (fix: remove agent Mach service or justify)
3. Network entitlements without justification (fix: scope to File Provider extension only)
4. FSKit entitlement not self-service (fix: apply through App Store Connect capabilities)

---

## v2 Planning (post-launch)

Once v1 ships and the app has a presence:
- Submit DriverKit entitlement request: **Block Storage Device** + **UserClient Access**
- Enable disk image mounting (QCOW2, VHDX, VMDK) via DriverKit virtual block device
- The dext (`DiskJockeyVirtualDisk.dext`) is already compiled and ready on `feat/qcow2-mount-via-fskit`
