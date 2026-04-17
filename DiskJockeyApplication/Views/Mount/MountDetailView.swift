import SwiftUI
import DiskJockeyLibrary

struct MountDetailView: View {
    let mountId: UUID
    let container: AppContainer

    @State private var showDeleteConfirmation = false
    @State private var isPerformingAction = false
    @State private var actionError: String?

    private var mountRepository: MountRepository { container.mountRepository }

    private var mount: Mount? {
        mountRepository.mounts.first { $0.id == mountId }
    }

    var body: some View {
        if let mount = mount {
            ScrollView {
                VStack(spacing: 0) {
                    // Header
                    mountHeader(mount)

                    Divider()
                        .padding(.horizontal, 24)

                    // Details
                    mountDetails(mount)

                    // Error banner
                    if let error = actionError {
                        errorBanner(error)
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    mountToggleButton(mount)
                    deleteButton
                }
            }
            .alert("Delete Mount", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    deleteMount(mount)
                }
            } message: {
                Text("Are you sure you want to delete \"\(mount.name)\"? This cannot be undone.")
            }
        } else {
            ContentUnavailableView(
                "Mount Not Found",
                systemImage: "questionmark.circle",
                description: Text("This mount may have been deleted")
            )
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func mountHeader(_ mount: Mount) -> some View {
        VStack(spacing: 12) {
            // Icon
            Image(systemName: mount.diskType.systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.accentColor.opacity(0.1))
                )

            // Name & type
            VStack(spacing: 4) {
                Text(mount.name)
                    .font(.title2)
                    .fontWeight(.semibold)

                HStack(spacing: 6) {
                    Text(mount.diskType.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("·")
                        .foregroundStyle(.tertiary)

                    statusBadge(mount)
                }
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func statusBadge(_ mount: Mount) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(mount.isMounted ? .green : .secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(mount.isMounted ? "Mounted" : "Unmounted")
                .font(.subheadline)
                .foregroundStyle(mount.isMounted ? .primary : .secondary)
        }
    }

    // MARK: - Details

    @ViewBuilder
    private func mountDetails(_ mount: Mount) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !mount.path.isEmpty {
                detailRow(label: "Path", value: mount.path)
            }

            if !mount.remotePath.isEmpty {
                detailRow(label: "Remote Path", value: mount.remotePath)
            }

            // Show metadata fields (host, port, username, etc.)
            let displayKeys = mount.metadata.keys
                .filter { $0 != "mount_id" && $0 != "path" }
                .sorted()

            ForEach(displayKeys, id: \.self) { key in
                if let value = mount.metadata[key], !value.isEmpty {
                    detailRow(label: key.capitalized, value: value)
                }
            }

            if let mountIdStr = mount.metadata["mount_id"] {
                detailRow(label: "Mount ID", value: mountIdStr)
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)

            Text(value)
                .font(.body)
                .textSelection(.enabled)

            Spacer()
        }
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    @ViewBuilder
    private func mountToggleButton(_ mount: Mount) -> some View {
        Button(action: { toggleMount(mount) }) {
            if isPerformingAction {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            } else {
                Label(
                    mount.isMounted ? "Unmount" : "Mount",
                    systemImage: mount.isMounted ? "eject" : "externaldrive.badge.checkmark"
                )
            }
        }
        .disabled(isPerformingAction)
    }

    private var deleteButton: some View {
        Button(action: { showDeleteConfirmation = true }) {
            Label("Delete", systemImage: "trash")
        }
        .disabled(isPerformingAction)
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
            Spacer()
            Button("Dismiss") { actionError = nil }
                .buttonStyle(.borderless)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yellow.opacity(0.1))
        )
        .padding(.horizontal, 24)
    }

    // MARK: - Mount Actions

    private func toggleMount(_ mount: Mount) {
        isPerformingAction = true
        actionError = nil

        Task {
            do {
                if mount.isMounted {
                    try await mountRepository.unmount(id: mount.id)
                } else {
                    try await mountRepository.mount(id: mount.id)
                }
            } catch {
                actionError = error.localizedDescription
            }
            isPerformingAction = false
        }
    }

    private func deleteMount(_ mount: Mount) {
        isPerformingAction = true
        actionError = nil

        Task {
            do {
                try await mountRepository.removeMount(id: mount.id)
            } catch {
                actionError = error.localizedDescription
                isPerformingAction = false
            }
        }
    }
}
