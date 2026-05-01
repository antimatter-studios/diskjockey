//
// RawDiskDetailView.swift — detail pane for an unmounted / unformatted
// block device.
//
// Sibling of AttachedDiskDetailView. That one is for volumes the system
// already mounted; this one is for media we'd want to *format* before it
// can become a useful volume — blank SD cards, USB sticks, partitions
// with unknown filesystems, etc.
//
// Format actions are deliberately disabled in this scaffold — the
// underlying Rust `fs_ext4_mkfs` / `fs_ntfs_mkfs` haven't been written
// yet. The buttons exist so the UX shape is visible (and so the wire-up
// when mkfs lands is just "swap the disabled-with-tooltip for the real
// admin-prompt subprocess invocation"). Each format action will trigger
// an admin password prompt every time — destructive, no caching of trust.
//

import SwiftUI
import AppKit

struct RawDiskDetailView: View {
    let bsdName: String
    let container: AppContainer

    @ObservedObject private var rawDisks: RawDisksModel
    @ObservedObject private var attachedDisks: AttachedDisksModel

    init(bsdName: String, container: AppContainer) {
        self.bsdName = bsdName
        self.container = container
        self.rawDisks = container.rawDisks
        self.attachedDisks = container.attachedDisks
    }

    private var disk: RawDisk? {
        rawDisks.disk(withBsdName: bsdName)
    }

    var body: some View {
        if let disk = disk {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(disk)

                    Divider()

                    detailsForm(disk)

                    if disk.isWhole {
                        partitionList(disk)
                    }

                    actionsSection(disk)

                    Spacer(minLength: 0)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            ContentUnavailableView(
                "Disk Disappeared",
                image: "tabler-externaldrive-badge-minus",
                description: Text("\(bsdName) is no longer attached.")
            )
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ disk: RawDisk) -> some View {
        HStack(spacing: 12) {
            Image(disk.isWhole
                  ? "externaldrive.badge.questionmark"
                  : "internaldrive")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(headerName(disk))
                        .font(.title2)
                        .bold()
                    statusBadge(disk)
                }
                Text(headerSubtitle(disk))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func headerName(_ disk: RawDisk) -> String {
        if let label = disk.volumeName, !label.isEmpty { return label }
        if disk.isWhole { return "Disk \(disk.bsdName)" }
        return "Partition \(disk.bsdName)"
    }

    private func headerSubtitle(_ disk: RawDisk) -> String {
        if disk.isUnformatted {
            return disk.isWhole
                ? "No filesystem · ready to format or partition"
                : "Empty partition slot · ready to format"
        }
        if disk.isWhole {
            return "Partition map: \(prettyContent(disk.content))"
        }
        return prettyContent(disk.content)
    }

    @ViewBuilder
    private func statusBadge(_ disk: RawDisk) -> some View {
        if disk.isUnformatted {
            Text("unformatted")
                .font(.caption2).bold()
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.orange))
        }
    }

    // MARK: - Details form

    @ViewBuilder
    private func detailsForm(_ disk: RawDisk) -> some View {
        Form {
            LabeledContent("BSD device", value: "/dev/" + disk.bsdName)
            LabeledContent("Size", value: humanBytes(disk.size))
            LabeledContent("Type") {
                Text(disk.isWhole ? "Whole disk" : "Partition")
            }
            LabeledContent("Content", value: prettyContent(disk.content))
            if let parent = disk.parentBsdName {
                LabeledContent("Parent disk", value: "/dev/" + parent)
            }
            LabeledContent("Removable") {
                yesNo(disk.isRemovable)
            }
            LabeledContent("Ejectable") {
                yesNo(disk.isEjectable)
            }
            LabeledContent("Internal") {
                yesNo(disk.isInternal)
            }
            if let mp = disk.mountPoint {
                LabeledContent("Mounted at", value: mp)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Partition list (for whole disks)

    @ViewBuilder
    private func partitionList(_ whole: RawDisk) -> some View {
        let slices = rawDisks.slices(of: whole)
        if !slices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Partitions")
                    .font(.headline)
                ForEach(slices) { slice in
                    sliceRow(slice)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func sliceRow(_ slice: RawDisk) -> some View {
        HStack(spacing: 8) {
            Image("tabler-internaldrive")
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(slice.volumeName ?? slice.bsdName)
                    .font(.body)
                Text("\(humanBytes(slice.size)) · \(prettyContent(slice.content))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if slice.isUnformatted {
                Text("empty")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.06)))
    }

    // MARK: - Actions

    /// Format / partition actions. All disabled in this scaffold; the
    /// real implementations land once `fs_ext4_mkfs` and `fs_ntfs_mkfs`
    /// exist in the Rust crates and `EXT4FileSystem.startFormat` is no
    /// longer ENOSYS. Comment + tooltip explain what *will* happen so
    /// nothing about this code is mysterious to a reader.
    @ViewBuilder
    private func actionsSection(_ disk: RawDisk) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Format / Partition")
                .font(.headline)

            Text("Each format or partition action will prompt for your administrator password. Formatting **erases all data** on the target — no exceptions. macOS shows a separate prompt every time so a mistaken double-click can't slip through.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(action: {}) {
                    Label("Format as ext4…", image: "tabler-square-grid-3x3")
                }
                .disabled(true)
                .help("Available once fs_ext4_mkfs lands in the Rust crate.")

                Button(action: {}) {
                    Label("Format as NTFS…", image: "tabler-square-grid-3x3-fill")
                }
                .disabled(true)
                .help("Available once fs_ntfs_mkfs lands in the Rust crate.")

                if disk.isWhole {
                    Button(action: {}) {
                        Label("Partition…", image: "tabler-rectangle-split-3x1")
                    }
                    .disabled(true)
                    .help("Will invoke `diskutil partitionDisk` with admin escalation. Not yet wired up.")
                }

                Spacer()
            }

            Text("Status: scaffold only — buttons disabled until the Rust mkfs is implemented.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }

    // MARK: - Formatting helpers

    @ViewBuilder
    private func yesNo(_ flag: Bool) -> some View {
        Text(flag ? "Yes" : "No")
            .foregroundStyle(flag ? .primary : .secondary)
    }

    private func humanBytes(_ n: UInt64) -> String {
        let labels = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = Double(n)
        var i = 0
        while i < labels.count - 1 && v >= 2048 { v /= 1024; i += 1 }
        return i == 0 ? "\(Int(v)) \(labels[i])"
                      : String(format: "%.1f %@", v, labels[i])
    }

    private func prettyContent(_ raw: String) -> String {
        switch raw {
        case "": return "(no filesystem)"
        case "GUID_partition_scheme": return "GPT (GUID Partition Table)"
        case "FDisk_partition_scheme": return "MBR (Master Boot Record)"
        case "Apple_HFS": return "HFS+"
        case "Apple_APFS", "Apple_APFS_Container": return "APFS"
        case "Apple_APFS_ISC": return "APFS (System Container)"
        case "Apple_APFS_Recovery": return "APFS Recovery"
        case "Apple_Boot": return "Apple Boot"
        case "EFI": return "EFI System Partition"
        case "Microsoft Basic Data": return "Windows / NTFS / exFAT"
        case "Linux": return "Linux"
        case "Linux_LVM": return "Linux LVM"
        case "Apple_Free": return "free space"
        default: return raw
        }
    }
}
