import SwiftUI
import DiskJockeyLibrary

/// Full-pane disk image inspector — shown when the user drops a disk
/// image onto the window. Displays container info, a GParted-style
/// partition map, per-partition details, and a mount control row.
/// Replaces the old alert-based flow for the drag-and-drop path.
struct DiskImageInspectorView: View {
    let url: URL
    let probe: DiskProbeResult
    let logRepository: LogRepository?
    let onDismiss: () -> Void

    @State private var isMounting = false
    @State private var mountError: String?

    init(url: URL, probe: DiskProbeResult, logRepository: LogRepository?, onDismiss: @escaping () -> Void) {
        self.url = url
        self.probe = probe
        self.logRepository = logRepository
        self.onDismiss = onDismiss
    }

    // MARK: - Map block model (pre-computed to avoid mutation inside @ViewBuilder)

    struct MapBlock: Identifiable {
        let id: Int
        let label: String
        let sublabel: String
        let fsKind: String
        let fraction: CGFloat
        let isUnallocated: Bool
        let supported: Bool
    }

    private var mapBlocks: [MapBlock] {
        let total = max(probe.containerSizeBytes, 1)
        if probe.table == "none" {
            let kind = probe.deviceFsKind ?? "unknown"
            return [MapBlock(
                id: 0,
                label: kind == "unknown" ? "Unknown" : kind.uppercased(),
                sublabel: formatBytes(probe.containerSizeBytes),
                fsKind: kind,
                fraction: 1.0,
                isUnallocated: kind == "unknown",
                supported: isMountableKind(kind)
            )]
        }
        var blocks: [MapBlock] = []
        var cursor: UInt64 = 0
        for part in probe.partitions {
            if part.start > cursor {
                let frac = CGFloat(part.start - cursor) / CGFloat(total)
                blocks.append(MapBlock(
                    id: blocks.count,
                    label: "Free",
                    sublabel: formatBytes(part.start - cursor),
                    fsKind: "unknown",
                    fraction: frac,
                    isUnallocated: true,
                    supported: false
                ))
            }
            let label = part.label.flatMap { $0.isEmpty ? nil : $0 } ?? part.fsKind.uppercased()
            blocks.append(MapBlock(
                id: blocks.count,
                label: label,
                sublabel: formatBytes(part.length),
                fsKind: part.fsKind,
                fraction: CGFloat(part.length) / CGFloat(total),
                isUnallocated: false,
                supported: isMountableKind(part.fsKind)
            ))
            cursor = part.start + part.length
        }
        if cursor < total {
            let frac = CGFloat(total - cursor) / CGFloat(total)
            blocks.append(MapBlock(
                id: blocks.count,
                label: "Free",
                sublabel: formatBytes(total - cursor),
                fsKind: "unknown",
                fraction: frac,
                isUnallocated: true,
                supported: false
            ))
        }
        return blocks
    }

    // MARK: - Body

    private var isMountableContainer: Bool {
        ["raw", "vhd", "vmdk"].contains(probe.container)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                partitionMapSection
                partitionListSection
                Divider()
                if isMountableContainer {
                    mountControls
                } else {
                    upcomingMountNotice
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "externaldrive")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(url.lastPathComponent)
                    .font(.title2).bold()
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(containerLabel)
                    Text("·")
                    Text(formatBytes(probe.containerSizeBytes))
                    Text("·")
                    Text(tableLabel)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Partition map

    private var partitionMapSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Partition Map")
                .font(.headline)

            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(mapBlocks) { block in
                        let w = max(block.isUnallocated ? 2 : 4, geo.size.width * block.fraction)
                        mapBlock(block: block, width: w)
                    }
                }
            }
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func mapBlock(block: MapBlock, width: CGFloat) -> some View {
        if block.isUnallocated {
            Rectangle()
                .fill(Color.gray.opacity(0.08))
                .frame(width: width)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                        .frame(height: 3)
                }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(block.label)
                    .font(.caption).bold()
                    .lineLimit(1)
                Text(block.sublabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(minWidth: width, maxWidth: width, maxHeight: .infinity, alignment: .leading)
            .background(fsColor(block.fsKind).opacity(block.supported ? 0.25 : 0.10))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(fsColor(block.fsKind).opacity(block.supported ? 0.8 : 0.3))
                    .frame(height: 3)
            }
        }
    }

    // MARK: - Partition list

    @ViewBuilder
    private var partitionListSection: some View {
        if probe.table != "none" && !probe.partitions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Partitions")
                    .font(.headline)

                ForEach(probe.partitions, id: \.index) { part in
                    partitionRow(part)
                }
            }
        }
    }

    private func partitionRow(_ part: DiskProbeResult.Partition) -> some View {
        let mountable = isMountableKind(part.fsKind)
        let driver = driverFor(part.fsKind)

        return HStack(spacing: 12) {
            Circle()
                .fill(fsColor(part.fsKind).opacity(mountable ? 0.7 : 0.3))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("p\(part.index)")
                        .font(.subheadline).bold()
                    Text(part.fsKind.uppercased())
                        .font(.subheadline)
                    if let label = part.label, !label.isEmpty {
                        Text("\"\(label)\"")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(formatBytes(part.length)) · \(driver)")
                    .font(.caption)
                    .foregroundStyle(mountable ? .secondary : .tertiary)
            }

            Spacer()

            Image(systemName: mountable ? "checkmark" : "minus")
                .font(.caption)
                .foregroundStyle(mountable ? Color.green : Color.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Upcoming notice (non-mountable container formats)

    private var upcomingMountNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.questionmark")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mounting coming in a future update")
                    .font(.subheadline).bold()
                Text("\(containerLabel) mounting will be available in an upcoming version of DiskJockey.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { onDismiss() }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Mount controls

    private var mountControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let err = mountError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // No name field: Disk Arbitration mounts each volume at its own
            // label and takes no mount point from us, so a name typed here
            // would reach nothing (diskjockey#290).
            HStack(alignment: .bottom, spacing: 12) {
                Text(mountHintText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(mountButtonLabel) {
                    performMount()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isMounting)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var mountButtonLabel: String {
        if isMounting { return "Mounting…" }
        if probe.table != "none" && !probe.partitions.isEmpty { return "Mount All" }
        return "Mount"
    }

    private var mountHintText: String {
        if probe.table != "none" && !probe.partitions.isEmpty {
            let count = probe.partitions.filter { isMountableKind($0.fsKind) }.count
            return "\(count) partition\(count == 1 ? "" : "s"), each under its own label in /Volumes"
        }
        return "Appears under its own label in /Volumes"
    }

    // MARK: - Mount action

    private func performMount() {
        isMounting = true
        mountError = nil

        Task { @MainActor in
            do {
                if probe.table != "none" && !probe.partitions.isEmpty {
                    let mounted = try await FSKitMountService.shared.attachAllPartitions(
                        imagePath: url.path,
                        imageURL: url,
                        partitions: probe.partitions,
                        container: probe.container
                    )
                    logRepository?.addLogEntry(LogEntry(
                        message: "inspector: mounted \(mounted.count) partition(s): \(mounted.map(\.described).joined(separator: ", "))",
                        category: "info", source: "FSKit"))
                } else {
                    // DA probes the device and picks the driver itself; there
                    // is no filesystem type to resolve first and pass on.
                    let mounted = try await FSKitMountService.shared.attach(imagePath: url.path)
                    logRepository?.addLogEntry(LogEntry(
                        message: "inspector: mounted \(url.lastPathComponent) at \(mounted.map(\.described).joined(separator: ", "))",
                        category: "info", source: "FSKit"))
                }
                onDismiss()
            } catch {
                mountError = error.localizedDescription
            }
            isMounting = false
        }
    }

    // MARK: - Helpers

    private var containerLabel: String {
        switch probe.container {
        case "raw":   return "Raw image"
        case "qcow2": return "QCOW2"
        case "vhd":   return "VHD"
        case "vhdx":  return "VHDX"
        case "vmdk":  return "VMDK"
        default: return probe.container.uppercased()
        }
    }

    private var tableLabel: String {
        switch probe.table {
        case "gpt":  return "GPT"
        case "mbr":  return "MBR"
        case "none": return "Single filesystem"
        default: return probe.table
        }
    }

    private func isMountableKind(_ kind: String) -> Bool {
        // EROFS / SquashFS are DiskJockey read-only filesystems. They
        // mount through the same hdiutil-attach + fs_core-slice path the
        // other DiskJockey drivers use, so they're only mountable from a
        // raw / VHD / VMDK source (same gate as the rest of `ours`).
        let ours: Set<String> = ["ext4", "ext3", "ext2", "ntfs", "squashfs", "erofs"]
        let apple: Set<String> = ["fat32", "fat16", "exfat", "hfs_plus", "apfs"]
        let hdiutilCompatible = ["raw", "vhd", "vmdk"].contains(probe.container)
        guard hdiutilCompatible else { return false }
        return ours.contains(kind) || apple.contains(kind)
    }

    private func driverFor(_ kind: String) -> String {
        // Read-only DiskJockey filesystems get a "(read-only)" qualifier
        // so the inspector row makes the capability obvious.
        let oursReadOnly: Set<String> = ["squashfs", "erofs"]
        let ours: Set<String> = ["ext4", "ext3", "ext2", "ntfs"]
        let apple: Set<String> = ["fat32", "fat16", "exfat", "hfs_plus", "apfs"]
        if oursReadOnly.contains(kind) { return isMountableContainer ? "DiskJockey (read-only)" : "coming soon" }
        if ours.contains(kind) { return isMountableContainer ? "DiskJockey" : "coming soon" }
        if apple.contains(kind) { return isMountableContainer ? "Apple" : "coming soon" }
        return "unsupported"
    }

    private func fsColor(_ kind: String) -> Color {
        switch kind {
        case "ext2", "ext3", "ext4": return .green
        case "ntfs": return .blue
        case "fat32", "fat16": return .yellow
        case "exfat": return .orange
        case "hfs_plus", "apfs": return .purple
        case "linux_swap": return .red
        // Read-only Linux-origin filesystems — teal/mint to read as
        // distinct from the writable ext* green.
        case "squashfs", "erofs": return .teal
        default: return .gray
        }
    }

    private func formatBytes(_ n: UInt64) -> String {
        let labels = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(n)
        var i = 0
        while i < labels.count - 1 && v >= 1500 { v /= 1024; i += 1 }
        return i == 0 ? "\(Int(v)) \(labels[i])" : String(format: "%.1f %@", v, labels[i])
    }
}
