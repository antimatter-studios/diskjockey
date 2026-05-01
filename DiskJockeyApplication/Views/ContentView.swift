import SwiftUI
import DiskJockeyLibrary

struct ContentView: View {
    let container: AppContainer

    @StateObject private var sidebarModel = SidebarModel()
    @State private var showingAddMount = false
    /// Driven by the custom sidebar-toggle button so we can group it
    /// next to "+" instead of macOS's auto toggle, which lands at the
    /// sidebar/detail boundary (visually marooned in the middle).
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    // Observed so the detail pane swaps out of the setup view the
    // moment the user picks a folder.
    @ObservedObject private var homeAccess: HomeAccessService

    init(container: AppContainer) {
        self.container = container
        self.homeAccess = container.homeAccess
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                container: container,
                sidebarModel: sidebarModel,
                showingAddMount: $showingAddMount,
                columnVisibility: $columnVisibility
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("")
        .frame(minWidth: 800, minHeight: 500)
        .sheet(isPresented: $showingAddMount) {
            AddMountView(
                directMountRegistry: container.directMountRegistry
            )
            .frame(minWidth: 520, minHeight: 460)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch sidebarModel.selectedItem {
        case .directMount(let id):
            DirectMountDetailView(mountID: id, container: container)
        case .logs:
            LogView()
                .environmentObject(container.appLogModel)
                .environmentObject(container.logRepository)
        case .addMount:
            ContentUnavailableView(
                "Add a Mount",
                image: "tabler-externaldrive-badge-plus",
                description: Text("Click the + button to add a new mount")
            )
        case .attachedDisk(let diskID):
            AttachedDiskDetailView(diskID: diskID, container: container)
        case .rawDisk(let bsd):
            RawDiskDetailView(bsdName: bsd, container: container)
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
    @Binding var columnVisibility: NavigationSplitViewVisibility

    @ObservedObject private var attachedDisks: AttachedDisksModel
    @ObservedObject private var directMountRegistry: DirectMountRegistry
    @ObservedObject private var rawDisks: RawDisksModel

    init(container: AppContainer,
         sidebarModel: SidebarModel,
         showingAddMount: Binding<Bool>,
         columnVisibility: Binding<NavigationSplitViewVisibility>) {
        self.container = container
        self.sidebarModel = sidebarModel
        self._showingAddMount = showingAddMount
        self._columnVisibility = columnVisibility
        self.attachedDisks = container.attachedDisks
        self.directMountRegistry = container.directMountRegistry
        self.rawDisks = container.rawDisks
    }

    var body: some View {
        VStack(spacing: 0) {
            // Mount list + logs
            List(selection: $sidebarModel.selectedItem) {
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
                }

                if !attachedDisks.disks.isEmpty {
                    Section("Local Drives") {
                        ForEach(attachedDisks.disks) { disk in
                            AttachedDiskSidebarRow(disk: disk)
                                .tag(SidebarItem.attachedDisk(disk.id))
                        }
                    }
                }

                if !rawDisks.formatableDisks.isEmpty {
                    Section("Unformatted Disks") {
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
            // Drop the auto sidebar toggle — macOS plants it at the
            // sidebar/detail boundary (looks orphaned in the middle of
            // the titlebar). We provide a custom one in the same
            // navigation group as "+" below.
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                // `.navigation` anchors both buttons to the leading
                // edge of the unified titlebar (left of the pane
                // boundary). Detail views supply their own
                // `.primaryAction` group on the trailing edge.
                ToolbarItemGroup(placement: .navigation) {
                    Button(action: { toggleSidebar() }) {
                        Image("tabler-sidebar-toggle")
                    }
                    .help("Show / Hide Sidebar")

                    Button(action: { showingAddMount = true }) {
                        Image("tabler-plus")
                    }
                    .help("Add Mount")
                }
            }
        }
    }

    /// Toggle between sidebar-visible and detail-only. `.automatic`
    /// resolves to `.all` on macOS when the window is wide enough, so
    /// we only need a binary flip.
    private func toggleSidebar() {
        withAnimation {
            columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
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
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                PersonalityIconView(disk.icon)
                    .foregroundStyle(isOffline ? .tertiary : .secondary)
                    .frame(width: 20, height: 20)
                if isOffline {
                    // Small unplug overlay so an offline row reads as
                    // "this disk is no longer attached" at a glance.
                    Image("tabler-bolt-horizontal-circle-fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary, Color(NSColor.windowBackgroundColor))
                        .offset(x: 2, y: 2)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(disk.name)
                    .font(.body)
                    .foregroundStyle(isOffline ? .secondary : .primary)
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

            if !disk.isWritable && !isOffline {
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
        .padding(.vertical, 2)
        .opacity(isOffline ? 0.65 : 1.0)
    }

    private var isOffline: Bool {
        if case .offline = disk.status { return true }
        return false
    }

    private var secondaryLine: String {
        switch disk.status {
        case .mounting:
            return "\(disk.fsType) · mounting…"
        case .live:
            return "\(disk.fsType) · \(disk.devicePath)"
        case .offline(let since):
            return "\(disk.fsType) · offline · " + Self.relativeTime.localizedString(for: since, relativeTo: Date())
        }
    }

    /// Transient status line. nil → not shown. Surfaces in-progress
    /// states the user wants visibility into:
    ///   - active fsck (highest priority — show progress %)
    ///   - .mounting preview (the disk has been detected but mount(8)
    ///     hasn't reported it yet — typically inside the fsck/load
    ///     window)
    private var transientLine: String? {
        if isOffline { return nil }
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

    /// Cached so we don't allocate a fresh formatter on every row body.
    /// Output is "5 min ago" / "2 hr ago" — short enough to fit the
    /// caption row without truncation on a typical sidebar width.
    private static let relativeTime: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var dotColor: Color {
        if isOffline { return .gray }
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
        switch disk.status {
        case .mounting:
            return "Mounting at \(disk.mountPath)…"
        case .offline(let since):
            return "Offline (was at \(disk.mountPath)) — last seen \(since.formatted(date: .abbreviated, time: .shortened))"
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
