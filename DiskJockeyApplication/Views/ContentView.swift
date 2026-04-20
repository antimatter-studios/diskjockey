import SwiftUI
import DiskJockeyLibrary

struct ContentView: View {
    let container: AppContainer

    @StateObject private var sidebarModel = SidebarModel()
    @State private var showingAddMount = false

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
        .frame(minWidth: 800, minHeight: 500)
        .sheet(isPresented: $showingAddMount) {
            AddMountView(
                diskTypeRepository: container.diskTypeRepository,
                mountRepository: container.mountRepository,
                directMountRegistry: container.directMountRegistry
            )
            .frame(minWidth: 480, minHeight: 400)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch sidebarModel.selectedItem {
        case .mount(let id):
            MountDetailView(mountId: id, container: container)
        case .directMount(let id):
            DirectMountDetailView(mountID: id, container: container)
        case .logs:
            LogView()
                .environmentObject(container.appLogModel)
                .environmentObject(container.logRepository)
        case .addMount:
            ContentUnavailableView(
                "Add a Mount",
                systemImage: "externaldrive.badge.plus",
                description: Text("Click the + button to add a new mount")
            )
        case .attachedDisk(let mountPath):
            AttachedDiskDetailView(mountPath: mountPath, container: container)
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
                    systemImage: "externaldrive",
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

    @ObservedObject private var mountRepository: MountRepository
    @ObservedObject private var attachedDisks: AttachedDisksModel
    @ObservedObject private var directMountRegistry: DirectMountRegistry

    init(container: AppContainer, sidebarModel: SidebarModel, showingAddMount: Binding<Bool>) {
        self.container = container
        self.sidebarModel = sidebarModel
        self._showingAddMount = showingAddMount
        self.mountRepository = container.mountRepository
        self.attachedDisks = container.attachedDisks
        self.directMountRegistry = container.directMountRegistry
    }

    var body: some View {
        VStack(spacing: 0) {
            // Backend status at top
            BackendStatusView(container: container)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            // Mount list + logs
            List(selection: $sidebarModel.selectedItem) {
                Section("Network Drives") {
                    let hasBackendMounts = !mountRepository.mounts.isEmpty
                    let hasDirectMounts = !directMountRegistry.mounts.isEmpty

                    // Direct mounts always render — they don't depend on
                    // the backend and live-render is essential for the
                    // mount-status dot.
                    ForEach(directMountRegistry.mounts, id: \.id) { mount in
                        DirectMountSidebarRow(
                            mount: mount,
                            registry: directMountRegistry
                        )
                        .tag(SidebarItem.directMount(mount.id))
                    }

                    // Backend-routed mounts: only render once the
                    // MountRepository has fetched from the backend.
                    // Loading state applies ONLY to this subset — it
                    // must not block direct mounts above from showing.
                    ForEach(mountRepository.mounts, id: \.id) { mount in
                        MountSidebarRow(mount: mount)
                            .tag(SidebarItem.mount(mount.id))
                    }

                    if mountRepository.isLoading && !hasBackendMounts {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 16, height: 16)
                            Text("Loading backend mounts…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if !hasBackendMounts && !hasDirectMounts {
                        Text("No mounts configured")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                if !attachedDisks.disks.isEmpty {
                    Section("Attached Disks") {
                        ForEach(attachedDisks.disks) { disk in
                            AttachedDiskSidebarRow(disk: disk)
                                .tag(SidebarItem.attachedDisk(disk.mountPath))
                        }
                    }
                }

                Section("System") {
                    Label("Logs", systemImage: "terminal")
                        .tag(SidebarItem.logs)
                }
            }
            .listStyle(.sidebar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingAddMount = true }) {
                        Image(systemName: "plus")
                    }
                    .help("Add Mount")
                }

                ToolbarItem(placement: .automatic) {
                    Button(action: refreshMounts) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                    .disabled(mountRepository.isLoading)
                }
            }
        }
    }

    private func refreshMounts() {
        Task { await mountRepository.fetchMounts() }
    }
}

// MARK: - Mount Sidebar Row

private struct MountSidebarRow: View {
    let mount: Mount

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: mount.diskType.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(mount.name)
                    .font(.body)
                    .lineLimit(1)
                Text(mount.diskType.displayName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if mount.isMounted {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                    .help("Mounted")
            }
        }
        .padding(.vertical, 2)
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
            Image(systemName: DiskTypeEnum.ftpDirect.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(mount.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(DiskTypeEnum.ftpDirect.displayName)
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
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(disk.name)
                    .font(.body)
                    .lineLimit(1)
                Text("\(disk.fsType) · \(disk.devicePath)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
                .help("Mounted at \(disk.mountPath)")
        }
        .padding(.vertical, 2)
    }
}
