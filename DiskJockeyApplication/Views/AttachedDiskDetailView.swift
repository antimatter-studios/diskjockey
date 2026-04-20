//
// AttachedDiskDetailView.swift — read-only detail pane for a system-mounted
// disk. No configuration options; just visibility + a Reveal-in-Finder
// shortcut.
//

import SwiftUI
import AppKit

struct AttachedDiskDetailView: View {
    let mountPath: String
    let container: AppContainer

    @ObservedObject private var attachedDisks: AttachedDisksModel

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
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
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
                .formStyle(.grouped)

                if case .running(let phase, let done, let total) = disk.fsckStatus {
                    progressBlock(phase: phase, done: done, total: total)
                }

                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: disk.mountPath)]
                        )
                    }
                    Spacer()
                }

                partitionLogSection(for: disk)

                Spacer()
            }
            .padding(20)
        } else {
            ContentUnavailableView(
                "Disk Unmounted",
                systemImage: "externaldrive.badge.minus",
                description: Text("\(mountPath) is no longer mounted.")
            )
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
            let detail = cleared
                ? "$LogFile reset (\(bytes) bytes), dirty bit cleared"
                : "Already clean (\(bytes) bytes scanned)"
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
            // ext4
            "block_size", "total_blocks", "free_blocks",
            "total_inodes", "free_inodes",
            // ntfs
            "cluster_size", "total_clusters", "total_size",
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
        case "ntfs_version":    return "NTFS version"
        case "serial_number":   return "Serial number"
        default:                return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Byte-valued fields become human readable ("12 GB"); counts keep
    /// thousands separators so big numbers are readable at a glance.
    private func formatInfoValue(key: String, value: String) -> String {
        if key == "total_size", let bytes = UInt64(value) {
            return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
        if ["total_blocks", "free_blocks", "total_clusters",
            "total_inodes", "free_inodes"].contains(key),
           let n = UInt64(value) {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            return f.string(from: NSNumber(value: n)) ?? value
        }
        if ["block_size", "cluster_size"].contains(key), let bytes = UInt64(value) {
            return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
        }
        return value
    }

    // MARK: - Per-partition log

    @ViewBuilder
    private func partitionLogSection(for disk: AttachedDisk) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Partition log")
                    .font(.headline)
                Spacer()
                Text("\(disk.partitionLog.count) lines")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if disk.partitionLog.isEmpty {
                        Text("No events recorded yet for this partition.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(8)
                    } else {
                        ForEach(disk.partitionLog.suffix(200)) { line in
                            partitionLogRow(line)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 260)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
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
