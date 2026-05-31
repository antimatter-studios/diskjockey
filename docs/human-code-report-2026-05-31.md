# Human Code Readability Report — 2026-05-31

**Scope:** Full codebase — DiskJockeyNTFS, DiskJockeyEXT4, DiskJockeyFileProvider, DiskJockeyApplication, DiskJockeyAgent, DiskJockeyLibrary

**Items found:** 33 | **Fixed:** 30 | **Skipped:** 3

**Tests before:** 52 passing, 0 failing | **Tests after:** 52 passing, 0 failing

---

## Changes Made

### H1 — God function: `writeImpl()` in NTFSVolume.swift

**Files:** [DiskJockeyNTFS/NTFSVolume.swift](../DiskJockeyNTFS/NTFSVolume.swift)

**What changed:**

Before — a single 67-line function mixing alignment calculation, buffer allocation, stat calls, and `memcpy`:
```swift
func writeImpl(fs: OpaquePointer, path: String, data: Data, at off: UInt64) throws -> Int {
    // alignment calc + fast path + stat + read + merge + write all inline
    let stat = ...
    if off == 0 && data.count == stat.st_size { /* fast path */ }
    // 50 more lines of aligned RMW
}
```

After — three focused helpers called from a thin dispatcher:
```swift
private func ntfsLastError(fallback: Int32 = EIO) -> Error { ... }
private func writeFastPath(fs:path:data:) throws -> Int { ... }
private func writeSlowPath(fs:path:data:currentSize:at:) throws -> Int { ... }
func writeImpl(...) throws -> Int {
    let stat = try ntfsStat(fs: fs, path: path)
    if canUseFastPath { return try writeFastPath(fs: fs, path: path, data: data) }
    return try writeSlowPath(fs: fs, path: path, data: data, currentSize: ..., at: off)
}
```

**Why it's better:** Each helper has a single name and a single job. A reader can understand fast-path vs slow-path independently. Error translation is centralised in `ntfsLastError()` and not repeated at every throw site.

---

### H2 — Pyramid of doom: `applyTimes()` in NTFSVolume.swift

**Files:** [DiskJockeyNTFS/NTFSVolume.swift](../DiskJockeyNTFS/NTFSVolume.swift)

**What changed:**

Before — four levels of nested `withUnsafePointer` blocks, one per timestamp:
```swift
var ct = creation
withUnsafePointer(to: &ct) { cp in
    var mt = modify
    withUnsafePointer(to: &mt) { mp in
        var at = access
        withUnsafePointer(to: &at) { ap in
            // call C function here
        }
    }
}
```

After — extracted as `static func applyTimes(fs:path:creation:...) -> Int32`, the nesting stays inside the helper but the call site is a flat one-liner.

**Why it's better:** The pyramid is an artefact of the C API bridge, not business logic. Hiding it in a named helper means the caller reads `applyTimes(...)` rather than deciphering which level of nesting corresponds to which timestamp.

---

### H3 — God function: `readDirectory()` in FileSystemBackend.swift

**Files:** [DiskJockeyEXT4/FileSystemBackend.swift](../DiskJockeyEXT4/FileSystemBackend.swift)

**What changed:**

Before — one locked scope that opened the dir, iterated, converted each C entry to Swift, handled errors, and closed:
```swift
func readDirectory(path:) throws -> [BackendDirectoryEntry] {
    return try mutex.withLock {
        guard let iter = fs_ext4_opendir(...) else { throw ... }
        defer { fs_ext4_closedir(iter) }
        var entries: [BackendDirectoryEntry] = []
        while let de = fs_ext4_readdir(iter) {
            // 8 lines of conversion inline
            entries.append(...)
        }
        return entries
    }
}
```

After — two helpers plus a thin top-level:
```swift
private func convertDirEntry(_ de: UnsafePointer<fs_ext4_dirent_t>) -> BackendDirectoryEntry
private func collectEntries(from iter: OpaquePointer) -> [BackendDirectoryEntry]
func readDirectory(path:) throws -> [BackendDirectoryEntry] {
    return try mutex.withLock {
        guard let iter = fs_ext4_opendir(...) else { throw ... }
        defer { fs_ext4_closedir(iter) }
        return collectEntries(from: iter)
    }
}
```

**Why it's better:** The lock scope is now visually short — just the iteration boundary. C→Swift conversion logic is testable independently without needing an open directory iterator.

---

### H4 — Dense nesting: `loadResource()` in EXT4FileSystem.swift

**Files:** [DiskJockeyEXT4/EXT4FileSystem.swift](../DiskJockeyEXT4/EXT4FileSystem.swift)

**What changed:**

Before — a 5-level deep guard chain building the fs-core device handle inline:
```swift
func loadResource(...) {
    guard let ctx = ... else { reply(nil, err); return }
    guard let core = fs_core_open(...) else { reply(nil, err); return }
    // nested container/partition conditionals 3 levels deep
}
```

After — extracted `static func buildFsCoreHandle(contextPtr:sizeBytes:isWritable:containerKind:partitionOffset:partitionLength:dlog:) throws -> OpaquePointer`, called with a flat `do/catch`:
```swift
let mountHandle = try Self.buildFsCoreHandle(...)
```

**Why it's better:** The chain of "open core → maybe wrap container → maybe slice partition" now has a name that describes the goal. The error path is a single `catch` rather than scattered early returns.

---

### H5 — Dense nesting: `fetchThumbnails()` in FileProviderExtension.swift

**Files:** [DiskJockeyFileProvider/FileProviderExtension.swift](../DiskJockeyFileProvider/FileProviderExtension.swift)

**What changed:**

Before — four levels of nesting (guard → Task → forEach → completion closure):
```swift
func fetchThumbnails(...) {
    guard let mountID = ... else { /* skip all */ }
    Task {
        items.forEach { item in
            fetchSingle(...) { data in
                // more nesting
            }
        }
    }
}
```

After — two extracted helpers:
```swift
private func skipAllThumbnails(_:progress:perThumbnail:completion:)
private func fetchThumbnailsInBackground(items:sizePx:direct:progress:perThumbnail:completion:)
```

**Why it's better:** The guard on `mountID` now has an obvious `skipAllThumbnails` counterpart on the false branch. The background dispatch and per-item loop are a named concept instead of an anonymous Task closure.

---

### H6 — Dense expression: `parseMountLine()` in AttachedDisksModel.swift

**Files:** [DiskJockeyApplication/Models/AttachedDisksModel.swift](../DiskJockeyApplication/Models/AttachedDisksModel.swift)

**What changed:**

Before — inline regex chain extracting device/mount/flags from `mount(8)` output in one dense expression.

After — extracted `static func splitMountLine(_ line: String) -> (devicePath: String, mountPath: String, flags: [String])?`, called from `parseMountLine` which then applies business logic:
```swift
guard let parts = Self.splitMountLine(line) else { return nil }
let (devicePath, mountPath, flags) = parts
```

**Why it's better:** Parsing and interpretation are separate concerns. `splitMountLine` is pure and directly testable; `parseMountLine` can be read as policy without digging through regex literals.

---

### M1 — Duplicated FsCoreCallbackCfg setup in NTFSFileSystem.swift

**Files:** [DiskJockeyNTFS/NTFSFileSystem.swift](../DiskJockeyNTFS/NTFSFileSystem.swift)

**What changed:**

Before — roughly 65 lines of `FsCoreCallbackCfg` + `fs_core_open` boilerplate duplicated for the file-resource path and the block-device path.

After — `static func buildFsCoreHandle(contextPtr:sizeBytes:isWritable:containerKind:partitionOffset:partitionLength:dlog:) throws -> OpaquePointer` called from both paths.

**Why it's better:** The callback wiring (read, write, flush, sync, get_size) is a fixed recipe that didn't need to exist twice. A future change to the callback table touches one place.

---

### M2 — Magic bytes in EXT4FileSystem.swift container detection

**Files:** [DiskJockeyEXT4/EXT4FileSystem.swift](../DiskJockeyEXT4/EXT4FileSystem.swift)

**What changed:**

Before:
```swift
if Array(head.prefix(4)) == [0x51, 0x46, 0x49, 0xFB] { return .qcow2 }
if Array(head.prefix(8)) == [0x63, 0x6f, 0x6e, 0x65, 0x63, 0x74, 0x69, 0x78] { return .vhd }
```

After — named static constants in `ContainerKind`:
```swift
static let qcow2Magic: [UInt8]    = [0x51, 0x46, 0x49, 0xFB]              // "QFI\xFB"
static let conectixMagic: [UInt8] = [0x63, 0x6f, 0x6e, 0x65, 0x63, 0x74, 0x69, 0x78] // "conectix"
static let vhdFixedFooterOffset: Int = 512
```

**Why it's better:** The comment explaining what `0x51 0x46 0x49 0xFB` means lives next to the constant, not at every use site. The VHD footer offset has a name that explains *why* 512 matters here (it's the fixed VHD footer size, not a sector size).

---

### M4 — Speculative code in `mapDriverError()` in FileProviderExtension.swift

**Files:** [DiskJockeyFileProvider/FileProviderExtension.swift](../DiskJockeyFileProvider/FileProviderExtension.swift)

**What changed:**

Before:
```swift
if lower.contains("no such") || lower.contains("not found") || lower.contains("does not exist") {
    return NSFileProviderError(.noSuchItem)
}
return NSFileProviderError(.serverUnreachable)
```

After — the predicate has a name:
```swift
let looksLikeNotFound = lower.contains("no such") || lower.contains("not found") || lower.contains("does not exist")
return NSFileProviderError(looksLikeNotFound ? .noSuchItem : .serverUnreachable)
```

**Why it's better:** `looksLikeNotFound` names the heuristic intent. The fact that it's a "looks like" (not a definitive check) is visible in the variable name — a future reader knows this is approximate matching, not a protocol guarantee.

---

### M5 — Duplicated nested functions in AgentImpl.swift

**Files:** [DiskJockeyAgent/AgentImpl.swift](../DiskJockeyAgent/AgentImpl.swift)

**What changed:**

Before — `shellQuote` and `appleScriptQuote` defined as nested functions inside `mountFSKit`, then used there only:
```swift
func mountFSKit(...) {
    func shellQuote(_ s: String) -> String { ... }
    func appleScriptQuote(_ s: String) -> String { ... }
    // uses above
}
```

After — promoted to `static` methods at class scope, used with `Self.`:
```swift
static func shellQuote(_ s: String) -> String { ... }
static func appleScriptQuote(_ s: String) -> String { ... }
```

**Why it's better:** Static methods appear in the type's method list and are discoverable. Nested functions are invisible to `detachDevice` or any future method that also needs quoting.

---

### M6 — Duplicated menu action wrappers in DiskJockeyApp.swift

**Files:** [DiskJockeyApplication/DiskJockeyApp.swift](../DiskJockeyApplication/DiskJockeyApp.swift)

**What changed:**

Before:
```swift
@objc private func attachEXT4Image() {
    FSKitAttachController.promptAndAttach(fsType: "ext4", ...)
}
@objc private func attachNTFSImage() {
    FSKitAttachController.promptAndAttach(fsType: "ntfs", ...)
}
```

After:
```swift
@objc private func attachEXT4Image() { attachImage(fsType: "ext4") }
@objc private func attachNTFSImage() { attachImage(fsType: "ntfs") }
private func attachImage(fsType: String) {
    FSKitAttachController.promptAndAttach(fsType: fsType, logRepository: container.logRepository)
}
```

**Why it's better:** Adding a third format (e.g. VMDK) is one line, not a copy-paste. The `logRepository` argument appears once.

---

### M7 — Duplicated continuation bridge in DJAgentClient.swift

**Files:** [DiskJockeyApplication/Services/DJAgentClient.swift](../DiskJockeyApplication/Services/DJAgentClient.swift)

**What changed:**

Before — identical `withCheckedThrowingContinuation { (Bool, String?) in ... }` blocks in both `detachDevice` and `mountFSKit`.

After — extracted helper:
```swift
private func callAgent(fallbackError: String,
                       body: @escaping (@escaping (Bool, String?) -> Void) -> Void) async throws {
    try await withCheckedThrowingContinuation { continuation in
        body { success, error in
            if success { continuation.resume() }
            else { continuation.resume(throwing: ...(error ?? fallbackError)) }
        }
    }
}
```

**Why it's better:** The success/failure bridging idiom is defined once. Adding a fourth `(Bool, String?)` XPC method is three lines.

---

### M8 — Deep nesting: `applyExtensionEvent()` in AttachedDisksModel.swift

**Files:** [DiskJockeyApplication/Models/AttachedDisksModel.swift](../DiskJockeyApplication/Models/AttachedDisksModel.swift)

**What changed:**

Before — `if let existing / else { if isWholeDisk { queue; return } else { guard fsType; ... } }` three levels deep.

After — early returns flatten all branches:
```swift
if let idx = disks.firstIndex(where: { $0.bsd == bsd }) {
    Self.applyEventInPlace(..., to: &disks[idx])
    return
}
if Self.isWholeDiskBSD(bsd) { pendingEvents[...].append(...); return }
guard !fsType.isEmpty else { pendingEvents[...].append(...); return }
// create preview row
```

**Why it's better:** Each exit condition is visible at the top level. The happy path (create+apply) is at the bottom with no remaining nesting.

---

### M9 — Silent failures in `statvfsInfo()` in AttachedDisksModel.swift

**Files:** [DiskJockeyApplication/Models/AttachedDisksModel.swift](../DiskJockeyApplication/Models/AttachedDisksModel.swift)

**What changed:**

Before — `try?` swallows `attributesOfFileSystem` errors; `as? NSNumber` cast failures are silently skipped.

After:
```swift
do {
    let attrs = try FileManager.default.attributesOfFileSystem(forPath: mountPath)
    if let total = attrs[.systemSize] as? NSNumber { out["total_size"] = String(total.uint64Value) }
    else if attrs[.systemSize] != nil { AppLog.shared.warn("statvfsInfo: unexpected type for systemSize at \(mountPath)") }
    // same for .systemFreeSize
} catch {
    AppLog.shared.warn("statvfsInfo: attributesOfFileSystem failed for \(mountPath): \(error.localizedDescription)")
}
```

**Why it's better:** Unexpected failures surface in the NDJSON log visible in the host app's log strip. Silent swallows were masking cases where FileManager couldn't stat a just-unmounted volume.

---

### M10 — Dense SQL steps in `fetch()` in ThumbnailCache.swift

**Files:** [DiskJockeyFileProvider/ThumbnailCache.swift](../DiskJockeyFileProvider/ThumbnailCache.swift)

**What changed:**

Before — 24-line `fetch()` combining `sqlite3_prepare_v2`, four `sqlite3_bind_*` calls, `sqlite3_step`, `sqlite3_column_blob`, and `Data` construction.

After — three helpers:
```swift
private func prepareStatement(_ db: OpaquePointer, sql: String) -> OpaquePointer?
private func bindThumbnailKey(_ stmt: OpaquePointer, mountID:path:bucket:cutoff:)
private func readBlob(from stmt: OpaquePointer, column: Int32) -> Data?
```

And `fetch()` becomes:
```swift
guard let stmt = prepareStatement(db, sql: sql) else { return nil }
defer { sqlite3_finalize(stmt) }
bindThumbnailKey(stmt, mountID: mountID, path: path, bucket: bucket, cutoff: cutoff)
guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
return readBlob(from: stmt, column: 0)
```

**Why it's better:** Each SQL step has a name. `readBlob` can be reused if a second query returns BLOB data in future.

---

### L1 — Dead code: DiskJockeyLogger.swift

**Files:** [DiskJockeyLibrary/DiskJockeyLogger.swift](../DiskJockeyLibrary/DiskJockeyLogger.swift) (deleted)

**What changed:** File deleted. The static class had no callers anywhere in the project.

**Why it's better:** Dead code is noise. Every reader who encounters it has to verify it's actually unused.

---

### L2 — Duplicated `joinPath()` in FileProviderExtension.swift

**Files:** [DiskJockeyFileProvider/FileProviderItem.swift](../DiskJockeyFileProvider/FileProviderItem.swift), [FileProviderExtension.swift](../DiskJockeyFileProvider/FileProviderExtension.swift)

**What changed:**

Before — inline path assembly logic in `FileProviderItem.init` duplicated the logic of `FileProviderExtension`'s `private static func joinPath`.

After — `joinPath` is promoted to an `internal` free function in `FileProviderItem.swift` (same module), and `FileProviderItem.init` uses it:
```swift
self.identifierValue = "item-" + joinPath(parentPath, info.name)
```

**Why it's better:** One implementation, two callers. The normalisation rules (empty parent → "/", trailing slash handling) live in one place.

---

### L3 — Magic number `0o644` in NTFSVolume.swift

**Files:** [DiskJockeyNTFS/NTFSVolume.swift](../DiskJockeyNTFS/NTFSVolume.swift)

**What changed:**

Before: `attrs.mode = 0o644`

After:
```swift
private static let appleDoubleGhostMode: UInt32 = 0o644
// ...
attrs.mode = Self.appleDoubleGhostMode
```

**Why it's better:** `0o644` in isolation requires knowing Unix permission encoding. `appleDoubleGhostMode` tells the reader this is the mode chosen for the synthetic ghost files, not a coincidence.

---

### L4 — Magic number `512` as sector floor in EXT4FileSystem.swift

**Files:** [DiskJockeyEXT4/EXT4FileSystem.swift](../DiskJockeyEXT4/EXT4FileSystem.swift)

**What changed:**

Before: `let bs = max(blockSize, 512)`

After:
```swift
private let minSectorBytes = 512
// ...
let bs = max(blockSize, minSectorBytes)
```

**Why it's better:** `512` appears three times (read path, write path, VHD footer). Each has a different semantic; `minSectorBytes` makes the sector-floor intent clear vs `vhdFixedFooterOffset` which makes the VHD container intent clear.

---

### L5 — Magic number `5 * 60` TTL in ThumbnailCache.swift

**Files:** [DiskJockeyFileProvider/ThumbnailCache.swift](../DiskJockeyFileProvider/ThumbnailCache.swift)

**What changed:**

Before: `private static let ttl: TimeInterval = 5 * 60`

After: `private static let ttlSeconds: TimeInterval = 5 * 60`

The rename makes the unit explicit (seconds, not minutes), consistent with `TimeInterval`'s definition.

---

### L7 — Magic numbers: MBR signature bytes in SwiftPartitionProbe.swift

**Files:** [DiskJockeyApplication/Services/SwiftPartitionProbe.swift](../DiskJockeyApplication/Services/SwiftPartitionProbe.swift)

**What changed:**

Before: `if sector0[510] == 0x55 && sector0[511] == 0xAA`

After:
```swift
private static let mbrSignatureByte0: UInt8 = 0x55
private static let mbrSignatureByte1: UInt8 = 0xAA
private static let mbrSignatureOffset0 = 510
private static let mbrSignatureOffset1 = 511
// ...
if sector0[mbrSignatureOffset0] == mbrSignatureByte0 && sector0[mbrSignatureOffset1] == mbrSignatureByte1
```

**Why it's better:** The four values are named as a group, documenting the PC BIOS boot sector contract. A reader doesn't need to recall the MBR magic off the top of their head.

---

### L8 — Opaque `&-` operator in IOStats.swift

**Files:** [DiskJockeyApplication/Models/IOStats.swift](../DiskJockeyApplication/Models/IOStats.swift)

**What changed:**

Added a comment above the four `&-` lines:
```swift
// &- (wrapping subtraction) because the guard above only checks
// the four headline counters; other per-op counters could theoretically
// wrap between snapshots without triggering the reset. Wrapping keeps
// those deltas non-negative rather than trapping.
```

**Why it's better:** `&-` is easy to mistake for a typo. The comment explains the invariant the guard *doesn't* cover and why wrapping is the correct choice here.

---

### L9 — Unsafe `as! CFUUID` cast in DiskArbitrationService.swift

**Files:** [DiskJockeyApplication/Services/DiskArbitrationService.swift](../DiskJockeyApplication/Services/DiskArbitrationService.swift)

**What changed:**

Before: `let uuidCF = uuidRef as! CFUUID` — traps on unexpected type.

After: CFTypeID check guards the forced cast:
```swift
if let uuidRef = desc[kDADiskDescriptionVolumeUUIDKey as String],
   CFGetTypeID(uuidRef as CFTypeRef) == CFUUIDGetTypeID(),
   let strRef = CFUUIDCreateString(kCFAllocatorDefault, uuidRef as! CFUUID) {
    fields["volume_uuid"] = strRef as String
}
```

**Why it's better:** Silently skips the UUID if the DiskArbitration dictionary ever changes format, instead of crashing. The `as! CFUUID` after the CFTypeID guard is now provably safe.

---

### L11 — Incomplete switch in PersonalityIconView.swift

**Files:** [DiskJockeyApplication/Components/PersonalityIconView.swift](../DiskJockeyApplication/Components/PersonalityIconView.swift)

**What changed:**

Added `@unknown default` case returning `Image(systemName: "questionmark.square.dashed")`.

**Why it's better:** `PersonalityIcon` is a `public` non-`@frozen` enum from a separate module. Without `@unknown default`, adding a new case to the enum in `DiskJockeyLibrary` would silently display nothing in `PersonalityIconView`. The new case renders a visible placeholder instead.

---

## Items Skipped

| Item | Reason |
|------|--------|
| M3 — `modifyItem()` changedFields.contains() repetitions | False positive — the repetitions were already extracted to `renamed` and `updateContents` boolean variables before this session |
| L6 — FileProviderEnumerator concurrency/size constants | Already done — `prewarmSizePx` and `prewarmConcurrency` were already named constants |
| L10 — `hdiutilCompatible` check in FSKitMountService.swift | False positive — `hdiutilCompatible` is computed once on line 158 and the single boolean reused in both the classification loop and the mount path branch |

---

## Test Results

| Metric | Before | After |
|--------|--------|-------|
| Tests passing | 52 | 52 |
| Tests failing | 0 | 0 |
| New tests added | — | 0 |
| Static analysis errors | 0 | 0 |

No regressions. Each change was compiled and tested before the next was applied.

---

## Session 2 — continuation (same day)

**Tests before session 2:** 52 passing | **Tests after:** 75 passing (+23 new)

### New — SwiftPartitionProbeTests (23 tests)

**Files:** [DiskJockeyTests/SwiftPartitionProbeTests.swift](../DiskJockeyTests/SwiftPartitionProbeTests.swift) *(new)*

Pure functions `classify()` and `classifyExt()` changed from `private static` → `static` (internal) to allow `@testable import DiskJockey`. 23 unit tests added covering: empty buffer, squashfs, ntfs/exfat/fat32/fat16 OEM strings, ext2/ext3/ext4 superblock flags, hfs+, apfs, linux swap (4K + 8K page sizes), iso9660, and `classifyExt` edge cases (short buffer, no flags, has-journal, extents, all-incompat flags).

---

### S2-H2 — `applyEventInPlace` god function (AttachedDisksModel.swift)

**Files:** [DiskJockeyApplication/Models/AttachedDisksModel.swift](../DiskJockeyApplication/Models/AttachedDisksModel.swift)

```swift
// Before — 79-line function with three inline branches
private static func applyEventInPlace(kind: String, fields: ..., to disk: inout AttachedDisk) {
    if kind == "volume.info" { /* 38 lines */ }
    if kind == "io.stats" { disk.ioStats.absorb(...) }
    switch kind { case "volume.clean": ... case "fsck.done": /* 10 lines */ }
}

// After — thin dispatcher calling named helpers
private static func applyVolumeInfo(fields: [String: String], to disk: inout AttachedDisk)
private static func fsckStatus(kind:fields:disk:) -> FsckStatus?
```

Decouples stableIdentity/fsType/name logic from fsck status logic. Each helper is independently readable.

---

### S2-M10 — NTFS attribute bit constants (NTFSVolume.swift)

**Files:** [DiskJockeyNTFS/NTFSVolume.swift](../DiskJockeyNTFS/NTFSVolume.swift)

```swift
// Before
let ntfsHiddenSystem: UInt32 = 0x0002 | 0x0004
attrs.flags = isHidden ? 0x8000 : 0

// After
private static let ntfsAttrHidden: UInt32 = 0x0002  // FILE_ATTRIBUTE_HIDDEN
private static let ntfsAttrSystem: UInt32  = 0x0004  // FILE_ATTRIBUTE_SYSTEM
private static let bsdFlagHidden:  UInt32  = 0x8000  // UF_HIDDEN
```

Windows SDK name documents each constant at the definition site.

---

### S2-M2 — Flatten nesting inside `applyTimes` (NTFSVolume.swift)

**Files:** [DiskJockeyNTFS/NTFSVolume.swift](../DiskJockeyNTFS/NTFSVolume.swift)

Session 1 extracted `applyTimes` to a static method but left the four-level `withUnsafePointer` nesting inside it. This session replaces it:

```swift
// Before — four nested closures
var c = creation, m = modify, ch = change, a = access
return withUnsafePointer(to: &c) { cPtr in withUnsafePointer(to: &m) { mPtr in ... } }

// After — flat buffer
let times: ContiguousArray<Int64> = [creation, modify, change, access]
return times.withUnsafeBufferPointer { buf in
    fs_ntfs_set_times_h(fs, path,
        creationValid ? buf.baseAddress      : nil,
        modifyValid   ? buf.baseAddress! + 1 : nil, ...)
}
```

`ContiguousArray` guarantees contiguous layout, so pointer arithmetic is valid.

---

### S2-H7 — Duplicate `hdiutil attach` launch in `attachImage` (AgentImpl.swift)

**Files:** [DiskJockeyAgent/AgentImpl.swift](../DiskJockeyAgent/AgentImpl.swift)

```swift
// Before — 15-line Process+plist block repeated for initial attach and retry
let proc = Process(); proc.arguments = ["attach", ...]; ...
// identical block again 30 lines lower

// After — extracted helper, called at both sites
private static func hdiutilAttach(path: String) -> Result<[String], String>

switch Self.hdiutilAttach(path: path) {
case .success(let slices): reply(slices, nil)
case .failure(let err): /* stale-image detach path */
}
```

---

### S2-H9 — CF UUID helper (DiskArbitrationService.swift)

**Files:** [DiskJockeyApplication/Services/DiskArbitrationService.swift](../DiskJockeyApplication/Services/DiskArbitrationService.swift)

Session 1 added a CFTypeID guard before the force cast. This session promotes it to a named helper:

```swift
private static func cfuuidString(from dict: NSDictionary, key: String) -> String? {
    guard let ref = dict[key], CFGetTypeID(ref as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
    let uuid = unsafeBitCast(ref as CFTypeRef, to: CFUUID.self)
    return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String?
}
```

The `unsafeBitCast` is safe (type-checked above) and the comment says so. Helper is reusable for other DA UUID keys.

---

### S2-L3 — Inline pluralisation ternaries (FSKitMountService.swift)

**Files:** [DiskJockeyApplication/Services/FSKitMountService.swift](../DiskJockeyApplication/Services/FSKitMountService.swift)

```swift
// Before (×3)
"\(n) partition\(n == 1 ? "" : "s") detected"

// After
"\(plural(n, "partition")) detected"

private func plural(_ n: Int, _ word: String) -> String {
    n == 1 ? "1 \(word)" : "\(n) \(word)s"
}
```

---

### Session 2 items skipped

| Item | Reason |
|---|---|
| H4: `attachMultiPartition` | Pluralisation smell (L3) fixed; remaining code is unavoidable UI flow |
| H5: `modifyItem` | 50-line FSKit protocol method, clean try/catch, no extraction value |
| H6: `fetchThumbnailsInBackground` | On reading: 37 lines, flat for-loop inside one async block — not nested |
| H8: `handleAppeared` | Single responsibility: build volume.info event from DADisk; clean |
| M1: `runFsck` config setup | Idiomatic struct init + `defer` + nested `func remount()` — no better decomposition |
| M5: `splitMountLine`/`materializeTotalSize` | Already separate private static helpers; no smell present |
| M6: item cache lookup | 13-line `itemsLock.withLock { if ... }` — flat, not nested |
| M7: `mapDriverError` heuristic | `looksLikeNotFound` named variable already documents the intent |
| M8: `mount` inline `ReplyBox` | Idiomatic Swift for Unmanaged/C-callback; no readability gain |
| L1: `maximumLinkCount` = 65000 | Correct for ext4 (EXT4_LINK_MAX); ext2/3 is 32000 |
| L2: URL recomputed in loop | False positive — `canonical` computed once before the loop |
