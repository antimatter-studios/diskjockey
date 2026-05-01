//
// AttachedDiskDetailView.swift — detail pane for a system-mounted disk.
// Read-only information + Reveal-in-Finder + Unmount.
//

import SwiftUI
import AppKit

struct AttachedDiskDetailView: View {
    let mountPath: String
    let container: AppContainer

    @ObservedObject private var attachedDisks: AttachedDisksModel

    /// Spinner shown on the Unmount button while `diskutil unmount` is
    /// in flight. Prevents a double-click from queuing a second unmount
    /// before the first finishes + toggles the row out of the sidebar.
    @State private var unmounting = false
    /// Surfaced failure from the unmount attempt (e.g. "Resource busy"
    /// when a Terminal has `cd`'d into the mountpoint).
    @State private var unmountError: String? = nil

    /// Spinner shown on the Verify button between tap and the FSKit
    /// extension picking up the call (i.e. the window before
    /// `disk.fsckStatus` flips into `.running`). Once the extension
    /// starts emitting `fsck.start`/`fsck.progress`, the running-state
    /// branch of the model takes over the visual.
    @State private var verifying = false
    /// Surfaced failure from spawning `fsck_fskit` (binary missing,
    /// permission denied on the raw device, etc). Kept distinct from
    /// `unmountError` so a stale error from one operation can't
    /// masquerade as the other.
    @State private var verifyError: String? = nil

    /// Global toggle gating the FSKit extension's per-entry
    /// enumerateDirectory log. Stored in the App Group so the
    /// extension reads the same value via `UserDefaults(suiteName:)`.
    /// Off by default — flip it on only when investigating something.
    @AppStorage(
        "verboseEnumerateLog",
        store: UserDefaults(suiteName: "group.com.antimatterstudios.diskjockey")
    )
    private var verboseEnumerateLog = false

    init(mountPath: String, container: AppContainer) {
        self.mountPath = mountPath
        self.container = container
        self.attachedDisks = container.attachedDisks
    }

    private var disk: AttachedDisk? {
        attachedDisks.disks.first { $0.mountPath == mountPath }
    }

    var body: some View {
        if let disk = disk {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    PersonalityIconView(disk.icon)
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading) {
                        HStack(spacing: 6) {
                            Text(disk.name)
                                .font(.title2)
                                .bold()
                            statusBadge(for: disk.fsckStatus)
                        }
                        Text("Mounted by the system — no configuration")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Form {
                    LabeledContent("Filesystem", value: disk.fsType)
                    LabeledContent("Device", value: disk.devicePath)
                    LabeledContent("Mount point", value: disk.mountPath)
                    LabeledContent("Mode") {
                        modeText(for: disk)
                    }
                    LabeledContent("Status") {
                        statusText(for: disk.fsckStatus)
                    }
                    if !disk.info.isEmpty {
                        Section("Volume info") {
                            ForEach(orderedInfoKeys(disk.info), id: \.self) { key in
                                LabeledContent(humanizeInfoKey(key),
                                               value: formatInfoValue(key: key, value: disk.info[key] ?? ""))
                            }
                        }
                    }
                }
                .formStyle(.columns)
                .frame(maxWidth: .infinity, alignment: .leading)

                if case .running(let phase, let done, let total) = disk.fsckStatus {
                    progressBlock(phase: phase, done: done, total: total)
                }

                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: disk.mountPath)]
                        )
                    }

                    if disk.fsType == "ext4" {
                        Button(action: { verify(disk) }) {
                            if verifying || isFsckRunning(disk.fsckStatus) {
                                HStack(spacing: 4) {
                                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                                    Text("Verifying…")
                                }
                            } else {
                                Label("Verify", systemImage: "stethoscope")
                            }
                        }
                        .disabled(verifying || unmounting || isFsckRunning(disk.fsckStatus))
                    }

                    Button(action: { unmount(disk) }) {
                        if unmounting {
                            HStack(spacing: 4) {
                                ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                                Text("Unmounting…")
                            }
                        } else {
                            Label("Unmount", systemImage: "eject")
                        }
                    }
                    .disabled(unmounting)

                    Spacer()
                }

                if let err = unmountError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.vertical, 4)
                }

                if let err = verifyError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.vertical, 4)
                }

                // Live I/O activity panel — re-reads `disk.ioStats`
                // each render, so the sparkline slides as the FSKit
                // extension emits new 1 Hz `io.stats` samples. FSKit
                // volumes have a real block device so we show the
                // physical track too.
                IOStatsSection(stats: disk.ioStats, showPhysical: true)

                diagnosticsSection()

                partitionLogSection(for: disk)
                    .layoutPriority(1)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ContentUnavailableView(
                "Disk Unmounted",
                systemImage: "externaldrive.badge.minus",
                description: Text("\(mountPath) is no longer mounted.")
            )
        }
    }

    // MARK: - Unmount

    /// Unmount via `diskutil unmount <mountPath>`. For FSKit-mounted
    /// volumes (ext4 / ntfs via our extensions) this routes through
    /// the fskitd / extension unloadResource path cleanly. No sudo
    /// needed — unmount of a user-mounted volume is a user-privileged
    /// operation. Errors (e.g. EBUSY when a shell has `cd`'d into the
    /// volume) surface via the `unmountError` banner.
    private func unmount(_ disk: AttachedDisk) {
        unmounting = true
        unmountError = nil
        Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            task.arguments = ["unmount", disk.mountPath]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            task.standardOutput = stdoutPipe
            task.standardError = stderrPipe
            do {
                try task.run()
                task.waitUntilExit()
                let rc = task.terminationStatus
                let err: String?
                if rc == 0 {
                    err = nil
                } else {
                    // diskutil writes its failure reason to stdout, not
                    // stderr (see "Unmount failed ..." lines), so merge
                    // both streams and surface whatever came out.
                    let out = (try? stdoutPipe.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let errText = (try? stderrPipe.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let combined = (out + errText).trimmingCharacters(in: .whitespacesAndNewlines)
                    err = combined.isEmpty ? "diskutil unmount failed (rc=\(rc))" : combined
                }
                await MainActor.run {
                    self.unmounting = false
                    self.unmountError = err
                }
            } catch {
                await MainActor.run {
                    self.unmounting = false
                    self.unmountError = "Could not run diskutil: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Verify

    /// True while the FSKit extension is actively running its check
    /// pass — gates the Verify button so the user can't double-fire a
    /// scan that's already in progress. Distinct from `verifying`
    /// (which only covers the brief tap → `fsck.start` window before
    /// the extension reports back).
    private func isFsckRunning(_ status: FsckStatus) -> Bool {
        if case .running = status { return true }
        return false
    }

    /// Trigger an fsck-lite verify pass via FSKit's standard maintenance
    /// hook. We invoke `fsck_fskit -t ext4 --progress <devicePath>`
    /// rather than `diskutil verifyVolume` because as of macOS 26
    /// `diskutil` does not route verify requests into FSKit modules —
    /// `fsck_fskit` is the documented user-space entry point that calls
    /// into our extension's `FSManageableResourceMaintenanceOperations
    /// .startCheck`. The extension drives all UI updates from there
    /// (status badge, progress bar, partition log) by emitting
    /// `fsck.start` / `fsck.progress` / `fsck.done` / `fsck.failed`
    /// NDJSON events that the model already consumes.
    ///
    /// Spawn pattern matches `unmount(_:)` above: detached Task,
    /// captured stdout+stderr, failure surfaced via the dedicated
    /// `verifyError` banner.
    private func verify(_ disk: AttachedDisk) {
        verifying = true
        verifyError = nil
        let devicePath = disk.devicePath
        let fsType = disk.fsType
        Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/sbin/fsck_fskit")
            task.arguments = ["--progress", "-t", fsType, devicePath]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            task.standardOutput = stdoutPipe
            task.standardError = stderrPipe
            do {
                try task.run()
                task.waitUntilExit()
                let rc = task.terminationStatus
                // rc == 0: clean. rc != 0 here means we couldn't even
                // launch the check (perm denied on raw device, missing
                // entitlement, etc) — actual fs-level findings come
                // back through the `fsck.done`/`fsck.failed` event
                // stream and render via statusText, not here.
                let err: String?
                if rc == 0 {
                    err = nil
                } else {
                    let out = (try? stdoutPipe.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let errText = (try? stderrPipe.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let combined = (out + errText).trimmingCharacters(in: .whitespacesAndNewlines)
                    err = combined.isEmpty ? "fsck_fskit failed (rc=\(rc))" : combined
                }
                await MainActor.run {
                    self.verifying = false
                    self.verifyError = err
                }
            } catch {
                await MainActor.run {
                    self.verifying = false
                    self.verifyError = "Could not run fsck_fskit: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Status rendering

    @ViewBuilder
    private func statusBadge(for status: FsckStatus) -> some View {
        switch status {
        case .dirty, .running:
            Text(status == .dirty ? "dirty" : "fsck")
                .font(.caption2).bold()
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(status == .dirty ? Color.red : Color.orange))
        case .completed(let cleared, _) where cleared:
            Text("repaired")
                .font(.caption2).bold()
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.green))
        case .failed:
            Text("fsck failed")
                .font(.caption2).bold()
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.red))
        default:
            EmptyView()
        }
    }

    /// Read-only / read-write indicator. RO is accented in orange to
    /// match the dirty-volume state — both flag "writes won't behave
    /// the way you'd expect", so they read with one visual idiom.
    @ViewBuilder
    private func modeText(for disk: AttachedDisk) -> some View {
        if disk.isWritable {
            Label("Read-write", systemImage: "pencil.circle.fill")
                .foregroundStyle(.green)
                .help("Mounted read-write — writes are allowed")
        } else {
            Label("Read-only", systemImage: "lock.fill")
                .foregroundStyle(.orange)
                .help("Mounted read-only — writes are not allowed")
        }
    }

    @ViewBuilder
    private func statusText(for status: FsckStatus) -> some View {
        switch status {
        case .unknown:
            Text("—").foregroundStyle(.tertiary)
        case .clean:
            Label("Clean", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .dirty:
            Label("Dirty (fsck pending)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .running(let phase, _, _):
            Label("Running fsck · \(phase)", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
        case .completed(let cleared, let bytes):
            // `cleared == true` covers both NTFS ($LogFile reset + dirty
            // bit cleared) and ext4 (anomalies repaired) — the model
            // collapses both into one boolean. `bytes` is whatever the
            // extension chose to count as "scanned/reset volume" — see
            // partition log for per-finding detail.
            let detail = cleared
                ? "Anomalies cleared (\(bytes) bytes touched) — see partition log"
                : "No anomalies found (\(bytes) bytes scanned)"
            Label(detail, systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .failed(let err):
            Label("fsck failed: \(err)", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    // MARK: - Volume-info rendering

    /// Stable display order. Known keys come first in a hand-picked order;
    /// anything unknown gets alphabetised at the end so future fields
    /// still show up without needing a code change here.
    private func orderedInfoKeys(_ info: [String: String]) -> [String] {
        let priority = [
            "fs",
            "volume_name",
            // cross-fs (statvfs-derived in the data layer, so present
            // for every mounted partition regardless of type)
            "total_size", "free_size",
            // ext4
            "block_size", "total_blocks", "free_blocks",
            "total_inodes", "free_inodes",
            // ntfs
            "cluster_size", "total_clusters",
            "ntfs_version", "serial_number",
        ]
        let known = priority.filter { info[$0] != nil }
        let rest = info.keys.filter { !priority.contains($0) }.sorted()
        return known + rest
    }

    private func humanizeInfoKey(_ key: String) -> String {
        switch key {
        case "fs":              return "FS"
        case "volume_name":     return "Volume name"
        case "block_size":      return "Block size"
        case "total_blocks":    return "Total blocks"
        case "free_blocks":     return "Free blocks"
        case "total_inodes":    return "Total inodes"
        case "free_inodes":     return "Free inodes"
        case "cluster_size":    return "Cluster size"
        case "total_clusters":  return "Total clusters"
        case "total_size":      return "Total size"
        case "free_size":       return "Free size"
        case "ntfs_version":    return "NTFS version"
        case "serial_number":   return "Serial number"
        default:                return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Byte-valued fields become human readable ("12 GB"); counts keep
    /// thousands separators so big numbers are readable at a glance.
    private func formatInfoValue(key: String, value: String) -> String {
        if ["total_size", "free_size", "block_size", "cluster_size"].contains(key),
           let bytes = UInt64(value) {
            return humanSize(bytes: bytes)
        }
        if ["total_blocks", "free_blocks", "total_clusters",
            "total_inodes", "free_inodes"].contains(key),
           let n = UInt64(value) {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            return f.string(from: NSNumber(value: n)) ?? value
        }
        return value
    }

    /// Byte formatter with a 2× unit-switch rule: stay in the current
    /// unit until the value hits 2048 of it, then step up one unit.
    /// The [1×, 2×) band of the larger unit (`1.0`–`1.99` KB, MB, …) is
    /// treated as an overlap zone — we stay in the smaller unit so the
    /// reader gets integer precision (e.g. 1536 KB rather than 1.5 MB)
    /// right across the unit boundary, which is where a single decimal
    /// in the bigger unit loses the most useful precision.
    ///
    /// Labels are Finder-style (1024-based maths, "KB"/"MB"/"GB"/"TB"/"PB"
    /// labels). KB is shown integer; MB and up get one decimal since a
    /// bare integer in those units hides meaningful variation.
    fileprivate func humanSize(bytes: UInt64) -> String {
        let labels = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var idx = 0
        while idx < labels.count - 1 && value >= 2048 {
            value /= 1024
            idx += 1
        }
        if idx <= 1 {
            return "\(Int(value)) \(labels[idx])"
        }
        return String(format: "%.1f %@", value, labels[idx])
    }

    // MARK: - Diagnostics

    /// A small section with debugging toggles. Today: only the
    /// per-entry enumerateDirectory log gate. Default off — flip on
    /// when investigating something. The flag is global (shared App
    /// Group UserDefaults), not per-disk; the toggle lives here for
    /// quick reach while looking at a specific volume.
    @ViewBuilder
    private func diagnosticsSection() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diagnostics")
                .font(.headline)
            Toggle("Verbose enumerate log", isOn: $verboseEnumerateLog)
                .toggleStyle(.switch)
            Text("Logs each child path the FSKit extension hands to macOS during directory listing. Useful for diagnosing missing-file or wrong-attributes issues. Off by default; can be very noisy when Spotlight indexes a freshly-mounted volume.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Per-partition log

    @ViewBuilder
    private func partitionLogSection(for disk: AttachedDisk) -> some View {
        let visible = visiblePartitionLog(for: disk)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Partition log")
                    .font(.headline)
                Spacer()
                ScopeFilterMenu(suppressed: $attachedDisks.suppressedScopes)
                Text("\(visible.count) of \(disk.partitionLog.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if visible.isEmpty {
                        Text(disk.partitionLog.isEmpty
                             ? "No events recorded yet for this partition."
                             : "All recorded events are hidden by the current scope filter.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(8)
                    } else {
                        // Newest-first so fresh events appear at the
                        // top where the user's eye already is. We take
                        // the tail 200 then reverse so order is
                        // "most recent → oldest of the 200".
                        ForEach(visible.suffix(200).reversed()) { line in
                            partitionLogRow(line)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Apply the model's per-mount scope denylist to this disk's
    /// partition log. Untagged entries (scope == nil) are always shown.
    private func visiblePartitionLog(for disk: AttachedDisk) -> [AttachedDiskLogLine] {
        let suppressed = attachedDisks.suppressedScopes
        if suppressed.isEmpty { return disk.partitionLog }
        return disk.partitionLog.filter { entry in
            guard let scope = entry.scope else { return true }
            return !suppressed.contains(scope)
        }
    }

    @ViewBuilder
    private func partitionLogRow(_ line: AttachedDiskLogLine) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(Self.rowTimestampFormatter.string(from: line.timestamp))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(line.level)
                .font(.caption2.bold())
                .foregroundStyle(logLevelColor(line.level))
                .frame(width: 44, alignment: .leading)
            Text(line.message)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
    }

    private func logLevelColor(_ level: String) -> Color {
        switch level.uppercased() {
        case "ERROR": return .red
        case "WARN":  return .orange
        case "DEBUG": return .gray
        default:      return .secondary
        }
    }

    private static let rowTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    @ViewBuilder
    private func progressBlock(phase: String, done: UInt64, total: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Phase: \(phase)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if total > 0 {
                    let pct = Int((Double(done) / Double(total)) * 100)
                    Text("\(pct)% (\(done)/\(total))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }
}
