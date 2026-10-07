//
// MountTableParser.swift — static helpers around `/sbin/mount` that
// `AttachedDisksModel.refresh()` uses to enumerate what the kernel
// currently has mounted.
//
// Extracted from `AttachedDisksModel` so the parsing layer is reachable
// from tests without spawning a real `mount(8)`, and so the model's
// orchestration role is no longer mixed with subprocess + statvfs
// plumbing. Pure namespace (case-less `enum`) — no instance state.
//

import Foundation

public enum MountTableParser {

    /// Runs `/sbin/mount` and parses each line into an `AttachedDisk`.
    /// Output format: `/dev/diskN on /Volumes/NAME (fstype, flag1, flag2, ...)`.
    /// Simpler + more portable than wrestling with Swift's `getfsstat`
    /// bridging, and mount(8) is always present.
    ///
    /// Each parsed row's `info` is populated with the statvfs(2)
    /// baseline (total/free size, fs type, volume name) so the detail
    /// view can render sizes immediately even for fs types DiskJockey
    /// doesn't own.
    public static func enumerate(fsTypesOfInterest: Set<String>) -> [AttachedDisk] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/mount")
        // Reading stdout before waiting was half the fix: stderr was
        // still an unread `Pipe()`, and a child blocked writing to a
        // full stderr never closes stdout, so the read that was meant
        // to prevent the deadlock blocks instead. The runner drains
        // both, concurrently.
        guard let result = try? ProcessRunner.run(proc) else { return [] }
        let text = result.stdoutText
        guard !text.isEmpty else { return [] }

        var results: [AttachedDisk] = []
        for line in text.split(separator: "\n") {
            guard var disk = parseMountLine(String(line),
                                            fsTypesOfInterest: fsTypesOfInterest) else {
                continue
            }
            disk.info = statvfsInfo(
                mountPath: disk.mountPath, fsType: disk.fsType, volumeName: disk.name
            )
            results.append(disk)
        }
        return results.sorted { $0.mountPath < $1.mountPath }
    }

    /// Parse a single `/sbin/mount` output line into an `AttachedDisk`.
    /// Reachable from tests without spawning a real `mount(8)`. Returns
    /// nil for malformed lines or fstypes outside the caller's interest
    /// set. Does **not** populate `info` — that's the live caller's job
    /// (via `statvfsInfo`) so the test path doesn't have to mock
    /// statvfs.
    public static func parseMountLine(_ line: String,
                                      fsTypesOfInterest: Set<String>) -> AttachedDisk? {
        // Format: "/dev/diskN on /Volumes/Foo (fstype, flag1, flag2)"
        guard let (devicePath, mountPath, flags) = splitMountLine(line) else { return nil }
        guard let fsType = flags.first, fsTypesOfInterest.contains(fsType) else { return nil }

        // macOS mount(8) emits "read-only" for RO mounts; older / other
        // tools sometimes emit the bare token "ro". Treat both as RO.
        let isWritable = !flags.contains("read-only") && !flags.contains("ro")
        return AttachedDisk(
            bsd: bsdName(from: devicePath),
            mountPath: mountPath,
            devicePath: devicePath,
            fsType: fsType,
            name: (mountPath as NSString).lastPathComponent,
            isWritable: isWritable
        )
    }

    /// Strip "/dev/" prefix off a devicePath. Uses prefix match so
    /// "/dev/disk6s2" → "disk6s2"; callers comparing against event
    /// `bsd` keys should match with hasPrefix.
    public static func bsdName(from devicePath: String) -> String {
        if devicePath.hasPrefix("/dev/") {
            return String(devicePath.dropFirst("/dev/".count))
        }
        return devicePath
    }

    /// True for whole-disk BSDs ("disk4") as opposed to slices
    /// ("disk4s1"). Whole-disk entries are containers for partitions,
    /// not mountable filesystems themselves — events keyed on them
    /// must be queued, not turned into `.mounting` preview rows.
    public static func isWholeDiskBSD(_ bsd: String) -> Bool {
        // Format: "diskN" → whole. "diskNsM" → slice. Anchored regex
        // requires at least one digit, matching the original
        // implementation that lived on `AttachedDisksModel`.
        return bsd.range(of: #"^disk\d+$"#, options: .regularExpression) != nil
    }

    /// Cross-filesystem baseline info derived from `FileManager`'s
    /// wrapper around `statvfs(2)`. Populated at enumerate-time for
    /// every mounted partition — including msdos, exfat, apfs, hfs+,
    /// and other types DiskJockey doesn't have an FSKit extension for
    /// — so the detail view can show total / free size without waiting
    /// on a `volume.info` event that will never come. For DJ-managed
    /// (ext4, ntfs), the richer event overlays fs-specific keys on top
    /// of this baseline in `AttachedDisksModel.refresh()`.
    public static func statvfsInfo(
        mountPath: String, fsType: String, volumeName: String
    ) -> [String: String] {
        var out: [String: String] = [
            "fs": fsType,
            "volume_name": volumeName,
        ]
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: mountPath)
            if let total = attrs[.systemSize] as? NSNumber {
                out["total_size"] = String(total.uint64Value)
            } else if attrs[.systemSize] != nil {
                AppLog.shared.warn("statvfsInfo: unexpected type for systemSize at \(mountPath)")
            }
            if let free = attrs[.systemFreeSize] as? NSNumber {
                out["free_size"] = String(free.uint64Value)
            } else if attrs[.systemFreeSize] != nil {
                AppLog.shared.warn("statvfsInfo: unexpected type for systemFreeSize at \(mountPath)")
            }
        } catch {
            AppLog.shared.warn("statvfsInfo: attributesOfFileSystem failed for \(mountPath): \(error.localizedDescription)")
        }
        return out
    }

    /// Force-unmount a zombie mount entry through DiskArbitration
    /// (`VolumeUnmounter`, `kDADiskUnmountOptionForce`). Not
    /// `diskutil unmount force`: storagekitd does not recognise FSKit
    /// volumes and refused every one of them (#166). Errors are logged
    /// at INFO (not ERROR) — the caller's expectation is "if there's a
    /// zombie, kill it; if there isn't, no problem." Asynchronous, so
    /// the caller (on `@MainActor`) does not wait.
    public static func forceUnmountStale(mountPath: String, bsd: String) {
        VolumeUnmounter.unmount(mountPath: mountPath, force: true) { error in
            if let error = error {
                AppLog.shared.info("zombie mount cleanup: bsd=\(bsd) path=\(mountPath) — not unmounted (likely already gone): \(error.localizedDescription)")
            } else {
                AppLog.shared.info("zombie mount cleanup: bsd=\(bsd) path=\(mountPath) — force unmount succeeded")
            }
        }
    }

    // MARK: - Private

    /// Split a mount(8) line into its three components. Returns nil for
    /// malformed lines (missing " on " or the parenthesised flag list).
    private static func splitMountLine(
        _ line: String
    ) -> (devicePath: String, mountPath: String, flags: [String])? {
        guard let onRange = line.range(of: " on ") else { return nil }
        let devicePath = String(line[..<onRange.lowerBound])
        let afterOn = line[onRange.upperBound...]

        guard let parenOpen = afterOn.range(of: " (") else { return nil }
        let mountPath = String(afterOn[..<parenOpen.lowerBound])
        let flagsBody = afterOn[parenOpen.upperBound...]

        guard let parenClose = flagsBody.range(of: ")", options: .backwards) else { return nil }
        let flags = flagsBody[..<parenClose.lowerBound]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        return (devicePath, mountPath, flags)
    }
}
