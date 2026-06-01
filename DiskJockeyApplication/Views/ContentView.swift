import SwiftUI
import UniformTypeIdentifiers
import DiskJockeyLibrary

struct ContentView: View {
    let container: AppContainer

    @StateObject private var sidebarModel = SidebarModel()
    @State private var showingAddMount = false
    /// Pending disk image — set when the user drops an image file onto the
    /// window. Presents `DiskImageInspectorView` in the detail pane until
    /// the user mounts or cancels.
    @State private var pendingDiskImage: (url: URL, probe: DiskProbeResult)?

    // Observed so the detail pane swaps out of the setup view the
    // moment the user picks a folder.
    @ObservedObject private var homeAccess: HomeAccessService

    init(container: AppContainer) {
        self.container = container
        self.homeAccess = container.homeAccess
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                container: container,
                sidebarModel: sidebarModel,
                showingAddMount: $showingAddMount
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("")
        // Bumped from 800 so the AttachedDisk detail pane's two-column
        // Volume info layout has room — sidebar (~240) + 24px gutters +
        // two ~360px columns squeezes if the floor stays at 800.
        .frame(minWidth: 960, minHeight: 500)
        .sheet(isPresented: $showingAddMount) {
            AddMountView(
                directMountRegistry: container.directMountRegistry
            )
            .frame(minWidth: 520, minHeight: 460)
        }
        // Drag a disk image anywhere onto the window → same flow as the
        // "Add Disk Image" sidebar button. We accept .fileURL rather
        // than a specific UTType so any extension (.img, .raw, .bin,
        // partition exports) goes through the auto-probe path.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDroppedImages(providers)
        }
    }

    private func handleDroppedImages(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                // SwiftPartitionProbe reads directly through the URL (no subprocess,
                // works inside the sandbox). Falls back to agent probe for container
                // formats (QCOW2/VHD/VHDX/VMDK) — agent is unsandboxed so it can
                // open the file even though the child-process diskprobe cannot.
                var probe = SwiftPartitionProbe.probe(at: url)
                if probe == nil {
                    probe = try? await DJAgentClient.shared.probeImage(atPath: url.path)
                }
                if let probe {
                    pendingDiskImage = (url: url, probe: probe)
                } else {
                    FSKitAttachController.attachUserPickedImage(
                        at: url, logRepository: container.logRepository)
                }
            }
        }
        return true
    }

    @ViewBuilder
    private var detailView: some View {
        if let pending = pendingDiskImage {
            DiskImageInspectorView(
                url: pending.url,
                probe: pending.probe,
                logRepository: container.logRepository,
                onDismiss: { pendingDiskImage = nil }
            )
        } else {
            sidebarDetailView
        }
    }

    @ViewBuilder
    private var sidebarDetailView: some View {
        switch sidebarModel.selectedItem {
        case .directMount(let id):
            // .id(id) forces SwiftUI to treat each mount as a distinct
            // view identity. Without it, switching between two
            // .directMount cases reuses the same view instance and the
            // detail's @State (actionError, isPerformingAction, etc.)
            // bleeds across mounts — the user sees a previous mount's
            // error banner on a new mount's pane. Same fix applied to
            // .attachedDisk and .rawDisk below.
            DirectMountDetailView(mountID: id, container: container)
                .id(id)
        case .logs:
            LogView()
                .environmentObject(container.appLogModel)
                .environmentObject(container.logRepository)
        case .attachedDisk(let diskID):
            AttachedDiskDetailView(diskID: diskID, container: container)
                .id(diskID)
        case .rawDisk(let bsd):
            RawDiskDetailView(bsdName: bsd, container: container)
                .id(bsd)
        case nil:
            // First-run case: no folder approved yet. Use the full
            // detail pane to explain what we're about to do before
            // the OS panel pops up. Once the user picks a folder,
            // hasFolder flips and we fall through to the regular
            // "select a mount" placeholder.
            if !homeAccess.hasFolder {
                NetworkDrivesSetupView(
                    homeAccess: homeAccess,
                    registry: container.directMountRegistry
                )
            } else {
                ContentUnavailableView(
                    "No Mount Selected",
                    image: "tabler-externaldrive",
                    description: Text("Select a mount from the sidebar or add a new one")
                )
            }
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    let container: AppContainer
    @ObservedObject var sidebarModel: SidebarModel
    @Binding var showingAddMount: Bool

    @ObservedObject private var attachedDisks: AttachedDisksModel
    @ObservedObject private var directMountRegistry: DirectMountRegistry
    @ObservedObject private var rawDisks: RawDisksModel

    init(container: AppContainer,
         sidebarModel: SidebarModel,
         showingAddMount: Binding<Bool>) {
        self.container = container
        self.sidebarModel = sidebarModel
        self._showingAddMount = showingAddMount
        self.attachedDisks = container.attachedDisks
        self.directMountRegistry = container.directMountRegistry
        self.rawDisks = container.rawDisks
    }

    var body: some View {
        VStack(spacing: 0) {
            // Mount list + logs
            List(selection: $sidebarModel.selectedItem) {
                Section("Local Drives") {
                    if attachedDisks.disks.isEmpty {
                        Text("No local volumes mounted")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(attachedDisks.disks) { disk in
                            AttachedDiskSidebarRow(disk: disk)
                                .tag(SidebarItem.attachedDisk(disk.id))
                        }
                    }

                    Button(action: {
                        FSKitAttachController.promptAndAttachAuto(
                            logRepository: container.logRepository)
                    }) {
                        Label("Add Disk Image", image: "tabler-plus")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                Section("Network Drives") {
                    if directMountRegistry.mounts.isEmpty {
                        Text("No mounts configured")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(directMountRegistry.mounts, id: \.id) { mount in
                            DirectMountSidebarRow(
                                mount: mount,
                                registry: directMountRegistry
                            )
                            .tag(SidebarItem.directMount(mount.id))
                        }
                    }

                    Button(action: { showingAddMount = true }) {
                        Label("Add Network Drive", image: "tabler-plus")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                if !rawDisks.formatableDisks.isEmpty {
                    // "Empty Drives" rather than "Unformatted Disks" —
                    // covers both the no-media-inserted case (whole-disk
                    // BSDs for empty SD-reader bays, USB hub card slots)
                    // and unformatted/raw partitions. Local Drives now
                    // only ever lists partitions with a real filesystem,
                    // so empty bays consistently land here instead of
                    // appearing as phantom Local Drives rows.
                    Section("Empty Drives") {
                        ForEach(rawDisks.formatableDisks) { disk in
                            RawDiskSidebarRow(disk: disk)
                                .tag(SidebarItem.rawDisk(disk.bsdName))
                        }
                    }
                }

                Section("System") {
                    Label("Logs", image: "tabler-terminal")
                        .tag(SidebarItem.logs)
                }
            }
            .listStyle(.sidebar)
            // Drop the auto sidebar toggle — sidebar is always visible
            // and we don't want the orphan button macOS plants at the
            // sidebar/detail boundary.
            .toolbar(removing: .sidebarToggle)
        }
    }
}

// MARK: - Direct Mount Sidebar Row

private struct DirectMountSidebarRow: View {
    let mount: DirectMount
    let registry: DirectMountRegistry

    /// Live mount state. Queried off NSFileProviderManager at appear
    /// time and after any mount/unmount action via observation of the
    /// registry's @Published mounts array (changes to `mounts` fire
    /// this `.task(id:)` re-run).
    @State private var isMounted: Bool? = nil

    var body: some View {
        HStack(spacing: 8) {
            PersonalityIconView(mount.config.scheme.icon)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(mount.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(mount.config.scheme.displayName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .help(statusLabel)
        }
        .padding(.vertical, 2)
        .task(id: mount.id) {
            isMounted = await registry.isMounted(mount)
        }
    }

    private var dotColor: Color {
        switch isMounted {
        case .some(true):  return .green
        case .some(false): return .gray
        case .none:        return .yellow
        }
    }

    private var statusLabel: String {
        switch isMounted {
        case .some(true):  return "Mounted"
        case .some(false): return "Not Mounted"
        case .none:        return "Checking…"
        }
    }

}

// MARK: - Attached Disk Sidebar Row
//
// A disk that was mounted by the system (either directly by our FSKit
// extension via auto-probe, or by `mount -F` from the CLI / Attach menu).
// Display-only; no configuration.
private struct AttachedDiskSidebarRow: View {
    let disk: AttachedDisk

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                PersonalityIconView(disk.icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(disk.name)
                        .font(.body)
                        .lineLimit(1)
                    Text(secondaryLine)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    // Third line — only shown while the disk is in a
                    // transitional / non-ready state (currently: fsck
                    // running). Click into the row to see the live
                    // fsck.progress lines streaming in the partition log.
                    if let transient = transientLine {
                        Text(transient)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if !disk.isWritable {
                    Image("tabler-lock-fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Mounted read-only — writes are not allowed")
                }

                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .help(tooltip)
            }

            // At-a-glance fullness gauge. Driven by total_size /
            // free_size from disk.info (statvfs, refreshed each poll
            // cycle). Hidden on rows whose filesystem hasn't reported
            // a total size yet — a flat-zero bar reads as "empty disk",
            // which is the wrong story for an unknown one.
            if let frac = usedFraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.blue.opacity(0.18))
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.blue)
                            .frame(width: geo.size.width * frac)
                    }
                }
                .frame(height: 3)
                .help(fillTooltip)
            }
        }
        .padding(.vertical, 2)
    }

    /// Fraction of the volume currently in use, in [0, 1]. Nil when we
    /// don't yet have a total size to anchor against (preview rows,
    /// fs types statvfs returns nothing for) — caller hides the bar.
    private var usedFraction: Double? {
        guard let total = UInt64(disk.info["total_size"] ?? ""),
              let free = UInt64(disk.info["free_size"] ?? ""),
              total > 0 else { return nil }
        let used = total > free ? total - free : 0
        return min(1.0, max(0.0, Double(used) / Double(total)))
    }

    private var fillTooltip: String {
        guard let frac = usedFraction else { return "" }
        return "\(Int(frac * 100))% full"
    }

    private var isFsckRunning: Bool {
        if case .running = disk.fsckStatus { return true }
        return false
    }

    private var secondaryLine: String {
        if isFsckRunning {
            return "\(disk.fsType) · running fsck"
        }
        switch disk.status {
        case .mounting:
            return "\(disk.fsType) · mounting…"
        case .live:
            return "\(disk.fsType) · \(disk.devicePath)"
        case .repairing:
            return "\(disk.fsType) · repairing…"
        case .repairFailed:
            return "\(disk.fsType) · repair failed"
        }
    }

    /// Transient status line. nil → not shown. Surfaces in-progress
    /// states the user wants visibility into:
    ///   - active fsck (highest priority — show progress %)
    ///   - .mounting preview (the disk has been detected but mount(8)
    ///     hasn't reached it yet)
    private var transientLine: String? {
        if case .running(let phase, let done, let total) = disk.fsckStatus {
            if total > 0 {
                let pct = Int((Double(done) / Double(total)) * 100)
                return "Verifying · \(phase) \(pct)%"
            }
            return "Verifying · \(phase)…"
        }
        if case .mounting = disk.status {
            return "Mounting · waiting for system to attach"
        }
        return nil
    }

    private var dotColor: Color {
        if isFsckRunning { return .orange }
        switch disk.fsckStatus {
        case .unknown:       return .green
        case .clean:         return .green
        case .dirty:         return .orange
        case .running:       return .orange
        case .completed:     return .green
        case .failed:        return .red
        }
    }

    private var tooltip: String {
        if case .running(let phase, _, _) = disk.fsckStatus {
            let where_ = disk.mountPath.isEmpty ? "" : " at \(disk.mountPath)"
            return "Running fsck\(where_) (\(phase))"
        }
        switch disk.status {
        case .mounting:
            return "Mounting at \(disk.mountPath)…"
        case .repairing:
            return "Repairing \(disk.mountPath) — volume is temporarily offline"
        case .repairFailed(let msg):
            return "Repair failed: \(msg)"
        case .live:
            let base = "Mounted at \(disk.mountPath)"
            switch disk.fsckStatus {
            case .unknown, .clean, .completed:
                return base
            case .dirty:
                return "\(base) — volume is dirty, fsck pending"
            case .running(let phase, _, _):
                return "\(base) — fsck running (\(phase))"
            case .failed(let err):
                return "\(base) — fsck failed: \(err)"
            }
        }
    }
}

// MARK: - Raw Disk Sidebar Row
//
// Removable media that's either unformatted or hosting partitions we
// want surfaced for format / repartition actions. Distinct from
// `AttachedDiskSidebarRow` — that one shows volumes the system has
// already mounted; this one shows storage that needs the user's
// attention before becoming a usable volume.
private struct RawDiskSidebarRow: View {
    let disk: RawDisk

    var body: some View {
        HStack(spacing: 8) {
            Image(iconName)
                .foregroundStyle(.orange)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    /// Headline label — prefer the user-visible volume name when it
    /// exists ("My SD Card"), otherwise fall back to the BSD device
    /// name so the row is at least addressable ("disk5s1").
    private var displayName: String {
        if let label = disk.volumeName, !label.isEmpty { return label }
        return disk.bsdName
    }

    /// Caption row — describes the *state* the user cares about for
    /// an unformatted disk: bytes available, partition map type or
    /// "no filesystem", and whether the slot is actually empty.
    private var secondaryLine: String {
        let sizeStr = formatBytes(disk.size)
        if disk.isUnformatted {
            return "\(sizeStr) · unformatted"
        }
        if disk.isWhole {
            return "\(sizeStr) · \(prettyContent(disk.content))"
        }
        return "\(sizeStr) · \(prettyContent(disk.content))"
    }

    /// Whole disks get the external-drive icon; slices / partitions
    /// get a smaller "internaldrive" glyph so the hierarchy reads at
    /// a glance even though we render flat (no expand/collapse yet).
    private var iconName: String {
        disk.isWhole ? "externaldrive.badge.questionmark" : "internaldrive"
    }

    private func prettyContent(_ raw: String) -> String {
        switch raw {
        case "": return "no filesystem"
        case "GUID_partition_scheme": return "GPT"
        case "FDisk_partition_scheme": return "MBR"
        case "Apple_HFS": return "HFS+"
        case "Microsoft Basic Data": return "Windows / NTFS"
        case "Linux": return "Linux"
        case "Linux_LVM": return "Linux LVM"
        case "EFI": return "EFI"
        default: return raw
        }
    }

    private func formatBytes(_ n: UInt64) -> String {
        let labels = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = Double(n)
        var i = 0
        while i < labels.count - 1 && v >= 2048 { v /= 1024; i += 1 }
        return i == 0 ? "\(Int(v)) \(labels[i])"
                      : String(format: "%.1f %@", v, labels[i])
    }
}
