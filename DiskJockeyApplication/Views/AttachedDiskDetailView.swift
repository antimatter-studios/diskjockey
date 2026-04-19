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
