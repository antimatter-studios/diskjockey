import SwiftUI
import AppKit
import DiskJockeyLibrary

/// Detail view for a direct-linked mount. Parallel to `MountDetailView`
/// but reads from `DirectMountRegistry` instead of `MountRepository`.
/// Exposes Reveal / Mount / Unmount / Remove.
struct DirectMountDetailView: View {
    let mountID: UUID
    let container: AppContainer

    @ObservedObject private var registry: DirectMountRegistry
    @State private var showDeleteConfirmation = false
    @State private var isPerformingAction = false
    @State private var actionError: String?
    /// Whether the connection-error banner has its detail section
    /// expanded — collapsed by default so the banner stays compact;
    /// the user can pop it open to read the raw Go-side message.
    @State private var connErrorDetailExpanded = false
    /// Live mount state — queried from NSFileProviderManager, not from
    /// local persistence. `nil` while the first query is in flight.
    @State private var isMounted: Bool? = nil

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
            VStack(spacing: 0) {
                header(mount)

                // Connection-error banner pinned above the scrollable
                // body so it stays visible while the user scrolls
                // through details / logs. Sourced from the registry's
                // `mountErrors` map, populated by `mount.error` events
                // emitted by the FileProvider extension.
                if let connErr = registry.connectionError(forDomainID: mount.domainID) {
                    connectionErrorBanner(connErr, mount: mount)
                }

                Divider()

                ScrollView {
                    VStack(spacing: 0) {
                        details(mount)

                        if let error = actionError {
                            errorBanner(error)
                        }

                        Divider()
                            .padding(.horizontal, 24)
                            .padding(.top, 8)

                        logStrip(for: mount)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                // `.titleAndIcon` overrides the macOS toolbar default
                // (icon-only in unified titlebar) so each button shows
                // its label next to its glyph.
                //
                // The leading `ToolbarSpacer(.flexible)` is what pushes
                // the group to the trailing edge: macOS 26 (Tahoe) packs
                // toolbar items toward the centre by default, so without
                // an explicit flex spacer the buttons end up clustered
                // mid-window instead of glued to the right.
                ToolbarSpacer(.flexible, placement: .primaryAction)
                ToolbarItemGroup(placement: .primaryAction) {
                    // Mount/Unmount toggle. Disabled while the status
                    // query is pending to avoid racing an action
                    // against a stale view of the world.
                    if let mounted = isMounted {
                        Button(action: { toggleMount(mount, currentlyMounted: mounted) }) {
                            Label(
                                mounted ? "Unmount" : "Mount",
                                image: mounted ? "tabler-eject" : "tabler-externaldrive-badge-plus"
                            )
                            .labelStyle(.titleAndIcon)
                        }
                        .disabled(isPerformingAction)
                    } else {
                        Button(action: {}) {
                            Label("Checking…", image: "tabler-hourglass")
                                .labelStyle(.titleAndIcon)
                        }
                        .disabled(true)
                    }

                    Button(action: { revealInFinder(mount) }) {
                        Label("Reveal in Finder", image: "tabler-folder")
                            .labelStyle(.titleAndIcon)
                    }
                    .disabled(isPerformingAction || isMounted != true)

                    Button(action: { showDeleteConfirmation = true }) {
                        Label("Remove", image: "tabler-trash")
                            .labelStyle(.titleAndIcon)
                    }
                    .disabled(isPerformingAction)
                }
            }
            .task(id: mount.id) {
                // Refresh on appear and whenever the selected mount
                // changes. Authoritative source is NSFileProviderManager.
                await refreshMountState(for: mount)
            }
            .alert("Remove Mount", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    removeMount(mount)
                }
            } message: {
                Text("Remove direct mount \"\(mount.displayName)\"? The FileProvider domain, stored credentials and the `~/diskjockey/\(mount.symlinkName)` symlink will all be deleted.")
            }
        } else {
            ContentUnavailableView(
                "Mount Not Found",
                image: "tabler-questionmark-circle",
                description: Text("This direct mount may have been removed")
            )
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ mount: DirectMount) -> some View {
        VStack(spacing: 12) {
            PersonalityIconView(mount.config.scheme.icon)
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.accentColor.opacity(0.1))
                )

            VStack(spacing: 4) {
                Text(mount.displayName)
                    .font(.title2)
                    .fontWeight(.semibold)

                HStack(spacing: 6) {
                    Text(mount.config.scheme.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("·")
                        .foregroundStyle(.tertiary)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        Text(statusLabel)
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
            detailRow(label: "Protocol", value: mount.config.scheme.displayName)
            // Per-protocol fields — mounts can be any scheme, so we
            // unpack the StoredMountConfig case rather than assuming
            // FTP-shaped fields.
            switch mount.config {
            case .ftp(let c):
                detailRow(label: "Host", value: c.host)
                detailRow(label: "Port", value: String(c.port))
                detailRow(label: "User", value: c.user)
                detailRow(label: "Remote Path", value: c.rootPath)
                detailRow(label: "FTPS", value: c.ftps ? "Yes" : "No")
            case .sftp(let c):
                detailRow(label: "Host", value: c.host)
                detailRow(label: "Port", value: String(c.port))
                detailRow(label: "User", value: c.user)
                detailRow(label: "Remote Path", value: c.rootPath)
                detailRow(label: "SSH Agent", value: c.useSSHAgent ? "Yes" : "No")
            case .smb(let c):
                detailRow(label: "Host", value: c.host)
                detailRow(label: "Port", value: String(c.port))
                detailRow(label: "Share", value: c.share)
                detailRow(label: "User", value: c.user)
                detailRow(label: "Remote Path", value: c.rootPath)
            case .dropbox(let c):
                detailRow(label: "App Key", value: c.appKey.isEmpty ? "(legacy long-lived token)" : c.appKey)
                if !c.accountLabel.isEmpty {
                    detailRow(label: "Account", value: c.accountLabel)
                }
                detailRow(label: "Refresh Token", value: "Stored in keychain")
            case .webdav(let c):
                detailRow(label: "URL", value: c.url)
                detailRow(label: "User", value: c.user)
                detailRow(label: "Path Prefix", value: c.pathPrefix)
            case .gdrive(let c):
                detailRow(label: "Client ID", value: c.clientID)
                detailRow(label: "Refresh Token", value: "Stored in keychain")
            case .s3(let c):
                detailRow(label: "Endpoint", value: c.endpoint)
                detailRow(label: "Bucket", value: c.bucket)
                detailRow(label: "Region", value: c.region)
                detailRow(label: "Access Key", value: c.accessKeyID)
                if !c.prefix.isEmpty {
                    detailRow(label: "Prefix", value: c.prefix)
                }
                detailRow(label: "TLS", value: c.secure ? "Yes" : "No")
                detailRow(label: "Path Style", value: c.usePathStyle ? "Yes" : "No")
                detailRow(label: "Secret Key", value: "Stored in keychain")
            case .onedrive(let c):
                detailRow(label: "Client ID", value: c.clientID)
                if !c.accountLabel.isEmpty {
                    detailRow(label: "Account", value: c.accountLabel)
                }
                detailRow(label: "Refresh Token", value: "Stored in keychain")
            }
            detailRow(label: "Symlink", value: "~/diskjockey/\(mount.symlinkName)")
            detailRow(label: "Domain ID", value: mount.domainID)
            detailRow(label: "Created", value: mount.createdAt.formatted(date: .abbreviated, time: .shortened))

            detailRow(label: "Fetch Thumbnails",
                      value: mount.policy.fetchThumbnails ? "On" : "Off")
            detailRow(label: "Background Fetch",
                      value: mount.policy.backgroundFetch ? "On" : "Off")

            // Live I/O activity panel — pulls the current snapshot
            // straight from the registry every render so SwiftUI's
            // diffing animates the sparkline as new samples arrive.
            // FileProvider has no underlying block device, so the
            // physical track is hidden.
            IOStatsSection(
                stats: registry.stats(forDomainID: mount.domainID),
                showPhysical: false
            )
            .padding(.top, 16)
        }
        .padding(24)
    }

    // MARK: - Per-mount log strip

    @ViewBuilder
    private func logStrip(for mount: DirectMount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Log")
                    .font(.headline)
                Spacer()
                let total = registry.mountLogs[mount.domainID]?.count ?? 0
                Text("\(total) lines")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            let lines = registry.logs(forDomainID: mount.domainID, tail: 200)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if lines.isEmpty {
                        Text("No log events for this mount yet.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(8)
                    } else {
                        ForEach(lines) { line in
                            logRow(line)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200, maxHeight: 360)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.06))
            )
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .padding(.top, 12)
    }

    @ViewBuilder
    private func logRow(_ line: AttachedDiskLogLine) -> some View {
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
            Image("tabler-exclamationmark-triangle-fill")
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

    /// Persistent banner for the most recent connection / op failure
    /// the FileProvider extension surfaced for this mount. Plain stack
    /// of wrapped Texts with no nested HStack/DisclosureGroup — earlier
    /// shapes ran into SwiftUI layout cycles that whited out the entire
    /// window on macOS. Keep this flat.
    @ViewBuilder
    private func connectionErrorBanner(_ err: MountConnectionError,
                                       mount: DirectMount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image("tabler-exclamationmark-triangle-fill")
                    .foregroundStyle(.red)
                Text(connErrorHeadline(err))
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Button(action: {
                    registry.dismissConnectionError(forDomainID: mount.domainID)
                    connErrorDetailExpanded = false
                }) {
                    Image("tabler-dismiss")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }

            Text(err.summary)
                .font(.callout)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)

            Button {
                connErrorDetailExpanded.toggle()
            } label: {
                Text(connErrorDetailExpanded ? "Hide raw error" : "Show raw error")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)

            if connErrorDetailExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(err.detail.isEmpty ? "(no underlying message)" : err.detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    /// "listDir(/home) failed" / "connect failed" / etc. Built from
    /// `op` + optional `path` so the banner has both context (what was
    /// attempted) and the human summary (why it broke).
    private func connErrorHeadline(_ err: MountConnectionError) -> String {
        let opLabel: String
        switch err.op {
        case "connect":  opLabel = "Connection failed"
        case "listDir":  opLabel = "Directory listing failed"
        case "stat":     opLabel = "Metadata lookup failed"
        case "fetchFile":opLabel = "File download failed"
        default:         opLabel = "\(err.op) failed"
        }
        if let p = err.path, !p.isEmpty {
            return "\(opLabel) — \(p)"
        }
        return opLabel
    }

    // MARK: - Status rendering

    private var statusColor: Color {
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

    // MARK: - Actions

    private func refreshMountState(for mount: DirectMount) async {
        let state = await registry.isMounted(mount)
        isMounted = state
    }

    private func toggleMount(_ mount: DirectMount, currentlyMounted: Bool) {
        isPerformingAction = true
        actionError = nil
        Task {
            defer { isPerformingAction = false }
            do {
                if currentlyMounted {
                    try await registry.unmountDomain(mount)
                } else {
                    try await registry.mountDomain(mount)
                }
                await refreshMountState(for: mount)
            } catch {
                actionError = error.localizedDescription
                // Refresh anyway — state may have changed even on error.
                await refreshMountState(for: mount)
            }
        }
    }

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
