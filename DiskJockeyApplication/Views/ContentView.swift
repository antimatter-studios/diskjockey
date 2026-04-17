import SwiftUI
import DiskJockeyLibrary

struct ContentView: View {
    let container: AppContainer

    @StateObject private var sidebarModel = SidebarModel()
    @State private var showingAddMount = false

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
                mountRepository: container.mountRepository
            )
            .frame(minWidth: 480, minHeight: 400)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch sidebarModel.selectedItem {
        case .mount(let id):
            MountDetailView(mountId: id, container: container)
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
        case nil:
            ContentUnavailableView(
                "No Mount Selected",
                systemImage: "externaldrive",
                description: Text("Select a mount from the sidebar or add a new one")
            )
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    let container: AppContainer
    @ObservedObject var sidebarModel: SidebarModel
    @Binding var showingAddMount: Bool

    @ObservedObject private var mountRepository: MountRepository

    init(container: AppContainer, sidebarModel: SidebarModel, showingAddMount: Binding<Bool>) {
        self.container = container
        self.sidebarModel = sidebarModel
        self._showingAddMount = showingAddMount
        self.mountRepository = container.mountRepository
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
                Section("Mounts") {
                    if mountRepository.mounts.isEmpty && !mountRepository.isLoading {
                        Text("No mounts configured")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(mountRepository.mounts, id: \.id) { mount in
                            MountSidebarRow(mount: mount)
                                .tag(SidebarItem.mount(mount.id))
                        }
                    }

                    if mountRepository.isLoading {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 16, height: 16)
                            Text("Loading...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
