//
// AttachedDisksModel.swift — enumerates filesystems that the system has
// already mounted (ext4 / ntfs / other FSKit-managed types) so they can
// appear in the sidebar for visibility. These are NOT user-configured
// mounts; they're whatever is currently attached + mounted by the kernel
// (hdiutil attach + auto-probe, SD card plug-in, FSKit extensions, etc).
//

import Foundation
import Combine
import DiskJockeyLibrary

/// Live fsck status for a volume. Drives the detail-pane status row +
/// progress bar. Updated in response to kind-tagged events emitted by
/// our FSKit extensions (`volume.dirty`, `fsck.start`, `fsck.progress`,
/// `fsck.done`, `fsck.failed`).
public enum FsckStatus: Equatable, Hashable {
    case unknown
    case clean
    case dirty
    case running(phase: String, done: UInt64, total: UInt64)
    case completed(dirtyCleared: Bool, logfileBytes: UInt64)
    case failed(String)
}

public struct AttachedDisk: Identifiable, Equatable, Hashable {
    public var id: String { mountPath }
    public let mountPath: String             // e.g. "/Volumes/inline-vol"
    public let devicePath: String            // e.g. "/dev/disk5"
    public let fsType: String                // e.g. "ext4"
    public let name: String                  // user-visible label
    /// Latest dirty/fsck status for this volume. Keyed into the model
    /// by correlating `fields["bsd"]` (e.g. "disk5") with this disk's
    /// devicePath tail.
    public var fsckStatus: FsckStatus = .unknown
    /// Volume identity/sizing emitted once by the FSKit extension at
    /// mount time (kind="volume.info"). Keys are FS-specific — ext4 has
    /// total_blocks / free_blocks / free_inodes; ntfs has total_clusters
    /// / total_size / ntfs_version. Detail view just iterates + formats.
    public var info: [String: String] = [:]
    /// Recent log lines emitted by the extension for THIS volume (events
    /// whose `fields["bsd"]` matches this disk's BSD). Capped at 500 to
    /// keep memory bounded. Shown in the partition detail view.
    public var partitionLog: [AttachedDiskLogLine] = []

    /// Sidebar + detail-header icon. Baseline is the generic external-
    /// drive glyph; when `fsType` names a filesystem that only ships on
    /// one OS family, we overlay an OS-flavored asset (ext* → Linux,
    /// ntfs* → Windows). Keep this list narrow — cross-platform types
    /// (msdos/exfat/apfs/hfs) stay on the baseline because they don't
    /// identify an OS of origin.
    public var icon: PersonalityIcon {
        switch fsType.lowercased() {
        case "ext2", "ext3", "ext4":
            return .asset("LinuxDrive")
        case "ntfs", "fsntfs", "ntfs-fskit":
            return .asset("WindowsDrive")
        default:
            return .sfSymbol("externaldrive.fill")
        }
    }
}

/// One log line scoped to a specific partition. Subset of AppLogLine —
/// only the fields the detail-view log strip needs.
public struct AttachedDiskLogLine: Identifiable, Equatable, Hashable {
    public let id = UUID()
    public let timestamp: Date
    public let level: String
    public let message: String
    public let source: String
}

/// NDJSON line in the form the model consumes: timestamp, level,
/// message, source + optional `bsd` resolved from the structured
/// `fields` block (or parsed from the plain-text message as a
/// fallback for legacy lines). LogTailService builds one of these
/// per line.
public struct ParsedLogLine {
    public let timestamp: Date
    public let level: String
    public let source: String
    public let message: String
    /// BSD device name (e.g. "disk6") if the event is tagged with one,
    /// or if the message text obviously refers to one. Routes to
    /// AttachedDisksModel's per-disk log strip.
    public let bsd: String?
    /// FileProvider domain identifier (NSFileProviderDomain.rawValue)
    /// if the event carries `fields["mount"]`. Routes to
    /// DirectMountRegistry's per-mount log strip.
    public let mount: String?
    public init(timestamp: Date, level: String, source: String,
                message: String, bsd: String?, mount: String? = nil) {
        self.timestamp = timestamp
        self.level = level
        self.source = source
        self.message = message
        self.bsd = bsd
        self.mount = mount
    }
}

@MainActor
public final class AttachedDisksModel: ObservableObject {
    /// Currently mounted disks filtered to the fstypes we care about.
    @Published public private(set) var disks: [AttachedDisk] = []

    /// Fstypes we display in the sidebar. By default shows everything
    /// that could realistically be an interesting disk (our own
    /// extensions' outputs + common external filesystems). Override at
    /// runtime if you want to narrow.
    public var fsTypesOfInterest: Set<String> = [
        "ext4",              // DiskJockeyEXT4 / fs-ext4
        "ntfs",              // Apple legacy ntfs.fs
        "fsntfs",            // DiskJockeyNTFS (our FSShortName)
        "ntfs-fskit",        // ext4-fskit project's old ntfsfskitd
        "msdos",             // FAT-family
        "exfat",             // Apple's built-in exFAT
    ]

    private var timer: Timer?
    private let pollInterval: TimeInterval
    /// Events that arrived keyed on a BSD we hadn't yet seen in the
    /// mount table (classic race: extension emits volume.info the
    /// instant it mounts, our /sbin/mount poller picks up the mount
    /// 0-3s later). Replayed in refresh() once the disk appears.
    private var pendingEvents: [String: [(kind: String, fields: [String: String])]] = [:]
    /// Same race but for plain log lines (no `kind` — just a message).
    /// Accumulated by BSD until the disk is in `disks`.
    private var pendingLogs: [String: [AttachedDiskLogLine]] = [:]
    private static let logCap = 500

    public init(pollInterval: TimeInterval = 3.0) {
        self.pollInterval = pollInterval
    }

    public func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        let fresh = Self.enumerate(fsTypesOfInterest: fsTypesOfInterest)

        // Preserve per-disk fsck status + info + per-partition log
        // across the mount-table re-poll, otherwise every 3-second
        // poll wipes "running" back to "unknown" and drops the
        // volume.info fields we already captured.
        let oldStatus = Dictionary(uniqueKeysWithValues: disks.map { ($0.mountPath, $0.fsckStatus) })
        let oldInfo = Dictionary(uniqueKeysWithValues: disks.map { ($0.mountPath, $0.info) })
        let oldLog = Dictionary(uniqueKeysWithValues: disks.map { ($0.mountPath, $0.partitionLog) })
        var merged = fresh.map { d -> AttachedDisk in
            var copy = d
            copy.fsckStatus = oldStatus[d.mountPath] ?? .unknown
            // Fresh statvfs baseline (fs, volume_name, total_size, free_size)
            // starts from `copy.info`; any prior extension-emitted keys
            // (cluster_size, total_inodes, serial_number, ...) overlay on
            // top. `total_size` from the extension overrides the statvfs
            // value when present, which is correct — extensions get the
            // bytes from the on-disk superblock, identical to but slightly
            // richer than what statvfs reports.
            for (k, v) in oldInfo[d.mountPath] ?? [:] {
                copy.info[k] = v
            }
            copy.partitionLog = oldLog[d.mountPath] ?? []
            return copy
        }

        // Replay any events / log lines that arrived for a disk before
        // it showed up in mount(8). This covers the launch-time race
        // where LogTailService reads existing ndjson before the first
        // mount-table poll completes.
        for i in merged.indices {
            let bsd = Self.bsdName(from: merged[i].devicePath)
            if let queued = pendingEvents.removeValue(forKey: bsd) {
                for ev in queued {
                    Self.applyEventInPlace(kind: ev.kind, fields: ev.fields, to: &merged[i])
                }
            }
            if let lines = pendingLogs.removeValue(forKey: bsd) {
                merged[i].partitionLog.append(contentsOf: lines)
                if merged[i].partitionLog.count > Self.logCap {
                    merged[i].partitionLog.removeFirst(merged[i].partitionLog.count - Self.logCap)
                }
            }
        }

        guard merged != disks else { return }

        let oldPaths = Set(disks.map { $0.mountPath })
        let newPaths = Set(fresh.map { $0.mountPath })
        for added in fresh where !oldPaths.contains(added.mountPath) {
            AppLog.shared.info("attached: \(added.fsType) at \(added.mountPath) (\(added.devicePath))")
        }
        for removedPath in oldPaths.subtracting(newPaths) {
            AppLog.shared.info("detached: \(removedPath)")
        }
        disks = merged
    }

    /// Strip "/dev/" prefix off a devicePath. Uses prefix match so
    /// "/dev/disk6s2" → "disk6s2"; callers comparing against event
    /// `bsd` keys should match with hasPrefix.
    private static func bsdName(from devicePath: String) -> String {
        if devicePath.hasPrefix("/dev/") {
            return String(devicePath.dropFirst("/dev/".count))
        }
        return devicePath
    }

    /// Apply a structured event emitted by an FSKit extension via the
    /// NDJSON tail. `bsd` is the BSD device name (e.g. "disk6") the
    /// extension attached itself to; we match by prefix of `devicePath`
    /// so both "/dev/disk6" and "/dev/disk6s2" resolve to the right
    /// volume. If the disk hasn't appeared in mount(8) yet, the event
    /// is buffered and replayed on the next refresh(). Routes by kind
    /// — dirty/fsck events update fsckStatus, volume.info populates
    /// the info dict that the detail view renders.
    public func applyExtensionEvent(kind: String, fields: [String: String]) {
        guard let bsd = fields["bsd"] else { return }
        let devSuffix = "/dev/" + bsd
        guard let idx = disks.firstIndex(where: { $0.devicePath.hasPrefix(devSuffix) }) else {
            // Disk not yet in the model — buffer and replay on next refresh.
            pendingEvents[bsd, default: []].append((kind: kind, fields: fields))
            return
        }
        Self.applyEventInPlace(kind: kind, fields: fields, to: &disks[idx])
    }

    /// Apply a plain NDJSON log line to the matching disk's partition
    /// log. Lines without an identifiable BSD are dropped (they belong
    /// in the central app log, not a per-partition view). Lines for an
    /// unknown BSD are buffered and flushed on refresh().
    public func applyLogLine(_ line: ParsedLogLine) {
        guard let bsd = line.bsd else { return }
        let devSuffix = "/dev/" + bsd
        let entry = AttachedDiskLogLine(
            timestamp: line.timestamp,
            level: line.level,
            message: line.message,
            source: line.source
        )
        guard let idx = disks.firstIndex(where: { $0.devicePath.hasPrefix(devSuffix) }) else {
            pendingLogs[bsd, default: []].append(entry)
            if pendingLogs[bsd]!.count > Self.logCap {
                pendingLogs[bsd]!.removeFirst(pendingLogs[bsd]!.count - Self.logCap)
            }
            return
        }
        disks[idx].partitionLog.append(entry)
        if disks[idx].partitionLog.count > Self.logCap {
            disks[idx].partitionLog.removeFirst(disks[idx].partitionLog.count - Self.logCap)
        }
    }

    /// Mutating event-apply logic extracted so `refresh()` can replay
    /// buffered events directly into the merged array without going
    /// through the published `disks` property.
    private static func applyEventInPlace(kind: String, fields: [String: String], to disk: inout AttachedDisk) {
        if kind == "volume.info" {
            var info = fields
            info.removeValue(forKey: "bsd")
            if let bytes = materializeTotalSize(from: info) {
                info["total_size"] = String(bytes)
            }
            // Overlay onto existing (statvfs-populated) info rather than
            // replacing — so free_size from `refresh()` survives alongside
            // the fs-specific keys the extension emits.
            for (k, v) in info { disk.info[k] = v }
            return
        }

        let newStatus: FsckStatus
        switch kind {
        case "volume.clean":
            newStatus = .clean
        case "volume.dirty":
            newStatus = .dirty
        case "fsck.start":
            newStatus = .running(phase: "starting", done: 0, total: 0)
        case "fsck.progress":
            let phase = fields["phase"] ?? "?"
            let done = UInt64(fields["done"] ?? "0") ?? 0
            let total = UInt64(fields["total"] ?? "0") ?? 0
            newStatus = .running(phase: phase, done: done, total: total)
        case "fsck.done":
            let dirtyCleared = (fields["dirty_cleared"] ?? "false") == "true"
            let logfileBytes = UInt64(fields["logfile_bytes"] ?? "0") ?? 0
            newStatus = .completed(dirtyCleared: dirtyCleared, logfileBytes: logfileBytes)
        case "fsck.failed":
            newStatus = .failed(fields["error"] ?? "unknown error")
        default:
            return
        }
        disk.fsckStatus = newStatus
    }

    /// Runs `/sbin/mount` and parses each line into an AttachedDisk.
    /// Output format: `/dev/diskN on /Volumes/NAME (fstype, flag1, flag2, ...)`.
    /// Simpler + more portable than wrestling with Swift's `getfsstat`
    /// bridging, and mount(8) is always present.
    private static func enumerate(fsTypesOfInterest: Set<String>) -> [AttachedDisk] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return [] }
        proc.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var results: [AttachedDisk] = []
        for line in text.split(separator: "\n") {
            // "/dev/diskN on /Volumes/Foo (fstype, flag1, flag2)"
            let s = String(line)
            guard let onRange = s.range(of: " on ") else { continue }
            let devicePath = String(s[..<onRange.lowerBound])
            let rest = s[onRange.upperBound...]
            guard let parenOpen = rest.range(of: " (") else { continue }
            let mountPath = String(rest[..<parenOpen.lowerBound])
            let flagsStr = rest[parenOpen.upperBound...]
            guard let parenClose = flagsStr.range(of: ")", options: .backwards) else { continue }
            let flagsBody = flagsStr[..<parenClose.lowerBound]
            let flags = flagsBody.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let fsType = flags.first else { continue }
            guard fsTypesOfInterest.contains(fsType) else { continue }

            let name = (mountPath as NSString).lastPathComponent
            var disk = AttachedDisk(
                mountPath: mountPath,
                devicePath: devicePath,
                fsType: fsType,
                name: name
            )
            disk.info = statvfsInfo(
                mountPath: mountPath, fsType: fsType, volumeName: name
            )
            results.append(disk)
        }
        return results.sorted { $0.mountPath < $1.mountPath }
    }

    /// Compute the concrete `total_size` in bytes for a managed
    /// filesystem's `volume.info` event. Dispatches by the `fs` field
    /// the extension emits, so each case uses the exact fields it
    /// knows it wrote — no "does this key exist" probing. Returns
    /// `nil` for fs types we don't own (the statvfs baseline already
    /// provided `total_size` for those at enumerate-time).
    private static func materializeTotalSize(from fields: [String: String]) -> UInt64? {
        switch fields["fs"] ?? "" {
        case "ext4":
            let blocks = UInt64(fields["total_blocks"] ?? "") ?? 0
            let blockSize = UInt64(fields["block_size"] ?? "") ?? 0
            let (product, overflow) = blocks.multipliedReportingOverflow(by: blockSize)
            return overflow ? nil : product
        case "ntfs":
            return UInt64(fields["total_size"] ?? "")
        default:
            return nil
        }
    }

    /// Cross-filesystem baseline info derived from `FileManager`'s wrapper
    /// around `statvfs(2)`. Populated at enumerate-time for every mounted
    /// partition — including msdos, exfat, apfs, hfs+, and other types
    /// DiskJockey doesn't have an FSKit extension for — so the detail
    /// view can show total / free size without waiting on a `volume.info`
    /// event that will never come for non-DJ-managed filesystems. For
    /// DJ-managed (ext4, ntfs), the richer event overlays fs-specific
    /// keys (block_size, total_inodes, serial_number, …) on top of this
    /// baseline in `refresh()`.
    private static func statvfsInfo(
        mountPath: String, fsType: String, volumeName: String
    ) -> [String: String] {
        var out: [String: String] = [
            "fs": fsType,
            "volume_name": volumeName,
        ]
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: mountPath) {
            if let total = attrs[.systemSize] as? NSNumber {
                out["total_size"] = String(total.uint64Value)
            }
            if let free = attrs[.systemFreeSize] as? NSNumber {
                out["free_size"] = String(free.uint64Value)
            }
        }
        return out
    }
}
