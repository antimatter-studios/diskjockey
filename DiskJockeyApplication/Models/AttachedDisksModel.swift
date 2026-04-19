//
// AttachedDisksModel.swift — enumerates filesystems that the system has
// already mounted (ext4 / ntfs / other FSKit-managed types) so they can
// appear in the sidebar for visibility. These are NOT user-configured
// mounts; they're whatever is currently attached + mounted by the kernel
// (hdiutil attach + auto-probe, SD card plug-in, FSKit extensions, etc).
//

import Foundation
import Combine

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

        // Preserve per-disk fsck status across the mount-table re-poll,
        // otherwise every 3-second poll wipes "running" back to "unknown".
        let oldStatus = Dictionary(uniqueKeysWithValues: disks.map { ($0.mountPath, $0.fsckStatus) })
        let merged = fresh.map { d -> AttachedDisk in
            var copy = d
            copy.fsckStatus = oldStatus[d.mountPath] ?? .unknown
            return copy
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

    /// Apply a structured fsck event from the NDJSON tail. `bsd` is the
    /// BSD device name (e.g. "disk6") the extension attached itself to;
    /// we match by suffix of `devicePath` so both "/dev/disk6" and
    /// "/dev/disk6s2" resolve to the right volume.
    public func applyFsckEvent(kind: String, fields: [String: String]) {
        guard let bsd = fields["bsd"] else { return }
        let devSuffix = "/dev/" + bsd
        guard let idx = disks.firstIndex(where: { $0.devicePath.hasPrefix(devSuffix) }) else {
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
        disks[idx].fsckStatus = newStatus
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
            results.append(AttachedDisk(
                mountPath: mountPath,
                devicePath: devicePath,
                fsType: fsType,
                name: name
            ))
        }
        return results.sorted { $0.mountPath < $1.mountPath }
    }
}
