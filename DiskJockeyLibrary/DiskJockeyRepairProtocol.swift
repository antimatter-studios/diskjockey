//
// DiskJockeyRepairProtocol.swift — file-based request/response contract
// for repair operations between the host app and each FSKit extension.
//
// WHY THIS EXISTS
// ---------------
// FSKit on Sequoia routes filesystem repair through `fsck_fskit` /
// `diskutil repairVolume` / Disk Utility. None of those reach our
// extension cleanly from a sandboxed MAS app:
//
//   - fsck_fskit needs `operator` group access to /dev/diskN
//   - diskutil's storagekitd XPC is unreachable from sandbox
//   - Disk Utility doesn't recognise third-party FSKit modules as
//     repair-capable on Sequoia (private probe-binary requirements)
//
// But we don't actually need any of those — the FSKit extension
// process already has the RW `FSBlockDeviceResource` handle FSKit
// granted it on mount. That handle is sufficient to drive our
// `audit_with_repair` Rust pass entirely in-process: same code path
// as `EXT4FileSystem.startCheck`, no unmount required, no admin
// required.
//
// HOW THE EXTENSION IS REACHED
// ----------------------------
// The host app and each FSKit extension already share a sandbox App
// Group (`group.com.antimatterstudios.diskjockey`). We use that App
// Group container as the IPC surface — the most boring, most
// MAS-defensible mechanism available:
//
//   1. Host app writes a request file:
//        <App Group>/Repair/<fsShortName>/request-<UUID>.json
//      → atomic write of a JSON-encoded `RepairRequest`.
//
//   2. Extension's RepairWatcher (started in the principal class's
//      init()) watches `<App Group>/Repair/<fsShortName>/` via a
//      DispatchSource on the directory FD. On any change it scans
//      for new request files, atomically renames each into a
//      `processing/` subdirectory (so concurrent watchers can't
//      double-pick), runs the repair, writes the result file
//      alongside the original name with `.result.json` suffix into
//      a `responses/` directory, and unlinks the in-flight file.
//
//   3. Host app polls / DispatchSource-watches the `responses/`
//      directory for the matching `<UUID>.result.json`. Once it
//      appears the host reads + deletes it, decodes the `RepairResult`,
//      and renders.
//
// Progress is emitted through the extension's existing NDJSON log
// file (`<App Group>/Logs/ext4.ndjson`) as `fsck.start` /
// `fsck.progress` / `fsck.done` events. The host app's
// `LogTailService` already routes those into
// `AttachedDisksModel.applyExtensionEvent`, so the per-disk detail
// view's progress UI updates automatically — only the trigger and
// final outcome need this file-based round-trip.
//
// WHY NOT XPC
// -----------
// Earlier iterations tried Info.plist-declared mach services and
// anonymous-listener-via-App-Group endpoint files. The first is
// silently ignored by ExtensionKit-extension bundles; the second
// works, uses only public API, and is documented by Apple as a
// supported pattern for app-extension → host IPC, but is uncommon
// enough to risk reviewer-friction at App Store review. File-based
// IPC inside an App Group container is uncontroversial — that's
// the textbook example of what App Groups exist for.
//

import Foundation

/// Request payload written by the host app, read by the extension.
public struct RepairRequest: Codable, Equatable, Hashable {
    /// Caller-generated unique id. The extension echoes this back in
    /// `RepairResult.id` so the host can correlate.
    public let id: UUID
    /// BSD device name without `/dev/` prefix (e.g. `"disk5s2"`). The
    /// extension looks this up in its live mounted-resources
    /// registry; an unknown bsd produces a `RepairResult.success ==
    /// false` reply.
    public let bsd: String
    /// Wall-clock time at submission. Useful for surfacing "in
    /// flight for N seconds" hints in the UI; not used for ordering
    /// (the file's mtime is the authoritative arrival time).
    public let submittedAt: Date

    public init(id: UUID = UUID(), bsd: String, submittedAt: Date = Date()) {
        self.id = id
        self.bsd = bsd
        self.submittedAt = submittedAt
    }
}

/// Response payload written by the extension after the repair pass
/// finishes (whether it succeeded or not).
public struct RepairResult: Codable, Equatable, Hashable {
    /// Echoes the request id so the host can match.
    public let id: UUID
    /// `true` iff the repair pass committed (or had nothing to
    /// commit) without error.
    public let success: Bool
    /// Human-readable summary suitable for the UI banner. On
    /// success: e.g. `"Repaired 4 anomalies."`. On failure: the
    /// error description.
    public let message: String
    /// Number of anomalies the repair pass actually wrote back.
    /// 0 on a clean volume; nil when the underlying driver doesn't
    /// report it (e.g. NTFS until in-process repair is wired).
    public let repairedCount: UInt64?
    /// Wall-clock time the extension wrote the response. Diff
    /// against `RepairRequest.submittedAt` to show "took N seconds."
    public let completedAt: Date

    public init(
        id: UUID,
        success: Bool,
        message: String,
        repairedCount: UInt64? = nil,
        completedAt: Date = Date()
    ) {
        self.id = id
        self.success = success
        self.message = message
        self.repairedCount = repairedCount
        self.completedAt = completedAt
    }
}

/// Resolves the App-Group-relative paths both sides agree on. Pure
/// pathing logic; no I/O. Hardcoded here so host and extensions can
/// never disagree on layout.
public enum DiskJockeyRepairFiles {
    /// App Group identifier shared between the host app and each
    /// FSKit extension. Both sides declare it via
    /// `com.apple.security.application-groups`.
    public static let appGroup = "group.com.antimatterstudios.diskjockey"

    /// Short directory name per filesystem type — the extension
    /// owns its own subtree so two extensions running concurrently
    /// can't see each other's traffic.
    public static func subdir(forFsType fsType: String) -> String? {
        switch fsType.lowercased() {
        case "ext2", "ext3", "ext4":
            return "ext4"
        case "ntfs", "fsntfs", "ntfs-fskit":
            return "ntfs"
        case "erofs", "fserofs", "squashfs", "fssquashfs":
            // Read-only, immutable filesystems. There is no in-process
            // repair pass to coordinate with — `startCheck` in their
            // extensions trivially reports clean and there is no write
            // path — so there is no App-Group repair subtree for them.
            return nil
        default:
            return nil
        }
    }

    /// Root directory holding all repair traffic for a given
    /// filesystem extension. Returns nil when the App Group
    /// container can't be located.
    public static func rootURL(forFsType fsType: String) -> URL? {
        guard let sub = subdir(forFsType: fsType) else { return nil }
        guard let dir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else { return nil }
        return dir
            .appendingPathComponent("Repair", isDirectory: true)
            .appendingPathComponent(sub, isDirectory: true)
    }

    /// Where the host app writes new requests. Extension watches
    /// this directory and atomically renames new files into
    /// `processingURL` to claim them.
    public static func requestsURL(forFsType fsType: String) -> URL? {
        rootURL(forFsType: fsType)?.appendingPathComponent("requests", isDirectory: true)
    }

    /// Where the extension stages a request while it's running, so
    /// concurrent watchers (or a restarted extension) can tell
    /// "claimed but not done" from "queued."
    public static func processingURL(forFsType fsType: String) -> URL? {
        rootURL(forFsType: fsType)?.appendingPathComponent("processing", isDirectory: true)
    }

    /// Where the extension writes results. Host watches this
    /// directory for `<request-uuid>.result.json` files.
    public static func responsesURL(forFsType fsType: String) -> URL? {
        rootURL(forFsType: fsType)?.appendingPathComponent("responses", isDirectory: true)
    }

    /// Filename for a request file. Suffix used by both ends so
    /// stale partial writes are easy to spot if they ever happen.
    public static func requestFilename(id: UUID) -> String {
        "request-\(id.uuidString).json"
    }

    /// Filename for a result file. Same id as the request.
    public static func resultFilename(id: UUID) -> String {
        "result-\(id.uuidString).json"
    }

    /// Convenience: ensure all three subdirectories exist. Safe to
    /// call from either side; uses `withIntermediateDirectories`.
    public static func ensureDirectories(forFsType fsType: String) throws {
        guard
            let requests = requestsURL(forFsType: fsType),
            let processing = processingURL(forFsType: fsType),
            let responses = responsesURL(forFsType: fsType)
        else { return }
        let fm = FileManager.default
        for url in [requests, processing, responses] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
