import SwiftUI
import AppKit
import DiskJockeyLibrary

/// Detail view for a direct-linked mount. Parallel to `MountDetailView`
/// but reads from `DirectMountRegistry` instead of `MountRepository`
/// and offers Reveal / Remove (not Mount/Unmount — the FileProvider
/// domain is always registered while the mount exists).
struct DirectMountDetailView: View {
    let mountID: UUID
    let container: AppContainer

    @ObservedObject private var registry: DirectMountRegistry
    @State private var showDeleteConfirmation = false
    @State private var isPerformingAction = false
    @State private var actionError: String?

    init(mountID: UUID, container: AppContainer) {
        self.mountID = mountID
        self.container = container
        self.registry = container.directMountRegistry
    }

    private var mount: DirectMount? {
        registry.mount(withID: mountID)
    }

    var body: some View {
        if let mount = mount {
            ScrollView {
                VStack(spacing: 0) {
                    header(mount)

                    Divider()
                        .padding(.horizontal, 24)

                    details(mount)

                    if let error = actionError {
                        errorBanner(error)
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: { revealInFinder(mount) }) {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .disabled(isPerformingAction)

                    Button(action: { showDeleteConfirmation = true }) {
                        Label("Remove", systemImage: "trash")
                    }
                    .disabled(isPerformingAction)
                }
            }
            .alert("Remove Mount", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    removeMount(mount)
                }
            } message: {
                Text("Remove direct mount \"\(mount.displayName)\"? The FileProvider domain, stored credentials and the `~/DiskJockey/\(mount.symlinkName)` symlink will all be deleted.")
            }
        } else {
            ContentUnavailableView(
                "Mount Not Found",
                systemImage: "questionmark.circle",
                description: Text("This direct mount may have been removed")
            )
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ mount: DirectMount) -> some View {
        VStack(spacing: 12) {
            Image(systemName: DiskTypeEnum.ftpDirect.systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.accentColor.opacity(0.1))
                )

            VStack(spacing: 4) {
                Text(mount.displayName)
                    .font(.title2)
                    .fontWeight(.semibold)

                HStack(spacing: 6) {
                    Text(DiskTypeEnum.ftpDirect.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("·")
                        .foregroundStyle(.tertiary)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text("Registered")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Details

    @ViewBuilder
    private func details(_ mount: DirectMount) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            detailRow(label: "Host", value: mount.config.host)
            detailRow(label: "Port", value: String(mount.config.port))
            detailRow(label: "User", value: mount.config.user)
            detailRow(label: "Remote Path", value: mount.config.rootPath)
            detailRow(label: "FTPS", value: mount.config.ftps ? "Yes" : "No")
            detailRow(label: "Symlink", value: "~/DiskJockey/\(mount.symlinkName)")
            detailRow(label: "Domain ID", value: mount.domainID)
            detailRow(label: "Created", value: mount.createdAt.formatted(date: .abbreviated, time: .shortened))
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

    // MARK: - Actions

    private func revealInFinder(_ mount: DirectMount) {
        isPerformingAction = true
        actionError = nil
        Task {
            defer { isPerformingAction = false }
            do {
                let url = try await registry.userVisibleURL(for: mount)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func removeMount(_ mount: DirectMount) {
        isPerformingAction = true
        actionError = nil
        Task {
            do {
                try await registry.removeMount(mount)
            } catch {
                actionError = error.localizedDescription
            }
            isPerformingAction = false
        }
    }
}
