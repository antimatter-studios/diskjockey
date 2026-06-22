//
// HomeView.swift — the landing page shown when DiskJockey opens.
//
// A welcome header, live at-a-glance counts for the three things the
// sidebar tracks (mounted volumes, configured network drives, empty
// drives), a showcase of the filesystems and protocols the app speaks,
// and the two primary "add" actions. Selected by default at launch
// (see ContentView / SidebarModel).
//

import SwiftUI
import AppKit
import DiskJockeyLibrary

struct HomeView: View {
    let container: AppContainer
    /// Opens the "Add Network Drive" sheet — the binding for it lives
    /// in ContentView, so the action is passed down as a closure.
    var onAddNetworkDrive: () -> Void

    // Observed so the stat cards stay live as disks mount/unmount and
    // mounts are added or removed.
    @ObservedObject private var attachedDisks: AttachedDisksModel
    @ObservedObject private var directMountRegistry: DirectMountRegistry
    @ObservedObject private var rawDisks: RawDisksModel

    init(container: AppContainer, onAddNetworkDrive: @escaping () -> Void) {
        self.container = container
        self.onAddNetworkDrive = onAddNetworkDrive
        self.attachedDisks = container.attachedDisks
        self.directMountRegistry = container.directMountRegistry
        self.rawDisks = container.rawDisks
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                stats
                filesystems
                quickActions
                Spacer(minLength: 0)
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(appName)
                    .font(.system(size: 30, weight: .bold))
                Text("Mount remote storage and disk images as native Finder volumes.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Version \(appVersion) (\(appBuild))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Stats

    private var stats: some View {
        HStack(spacing: 14) {
            StatCard(
                value: attachedDisks.disks.count,
                label: "Local volumes",
                systemImage: "internaldrive"
            )
            StatCard(
                value: directMountRegistry.mounts.count,
                label: "Network drives",
                systemImage: "network"
            )
            StatCard(
                value: rawDisks.formatableDisks.count,
                label: "Empty drives",
                systemImage: "externaldrive.badge.questionmark"
            )
        }
    }

    // MARK: - Filesystems showcase

    private var filesystems: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Supported filesystems")

            // Local block-device filesystems, with their access mode.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                FSBadge(name: "ext4", mode: .readWrite)
                FSBadge(name: "NTFS", mode: .readWrite)
                FSBadge(name: "EROFS", mode: .readOnly)
                FSBadge(name: "SquashFS", mode: .readOnly)
            }

            chipGroup(
                title: "Disk image containers",
                items: ["qcow2", "VHD", "VHDX", "VMDK"]
            )
            chipGroup(
                title: "Network & cloud",
                items: ["SMB", "FTP", "SFTP", "WebDAV", "S3",
                        "Dropbox", "Google Drive", "OneDrive"]
            )
        }
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Quick actions")
            HStack(spacing: 12) {
                Button {
                    FSKitAttachController.promptAndAttachAuto(
                        logRepository: container.logRepository)
                } label: {
                    Label("Add Disk Image", systemImage: "plus")
                        .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    onAddNetworkDrive()
                } label: {
                    Label("Add Network Drive", systemImage: "plus")
                        .frame(minWidth: 150)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
    }

    private var appIcon: NSImage? {
        if let icon = NSApp?.applicationIconImage { return icon }
        return NSImage(named: NSImage.applicationIconName)
    }

    private var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "DiskJockey"
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }

    private var appBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
    }
}

// MARK: - Stat card

private struct StatCard: View {
    let value: Int
    let label: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }
}

// MARK: - Filesystem badge

private enum FSAccessMode {
    case readWrite
    case readOnly

    var label: String {
        switch self {
        case .readWrite: return "Read & write"
        case .readOnly:  return "Read-only"
        }
    }

    var systemImage: String {
        switch self {
        case .readWrite: return "square.and.pencil"
        case .readOnly:  return "lock"
        }
    }

    var tint: Color {
        switch self {
        case .readWrite: return .green
        case .readOnly:  return .secondary
        }
    }
}

private struct FSBadge: View {
    let name: String
    let mode: FSAccessMode

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: mode.systemImage)
                .foregroundStyle(mode.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.body.weight(.medium))
                Text(mode.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }
}

// MARK: - Chip group

private extension HomeView {
    func chipGroup(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(items, id: \.self) { Chip(text: $0) }
            }
        }
    }
}

private struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
}
