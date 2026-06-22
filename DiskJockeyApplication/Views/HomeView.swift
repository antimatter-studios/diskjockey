//
// HomeView.swift — the landing page shown when DiskJockey opens.
//
// A welcome header, live at-a-glance counts for the three things the
// sidebar tracks (mounted volumes, configured network drives, empty
// drives), a capability showcase that reflects what's actually ENABLED
// on this Mac, and the two primary "add" actions. Selected by default
// at launch (see ContentView / SidebarModel).
//
// The capability showcase is honest about what macOS actually lets the
// user toggle:
//   - Filesystems (ext4/NTFS/EROFS/SquashFS) are four separate FSKit
//     extensions, each with its own on/off switch → real Enabled vs
//     Disabled columns, read live from ExtensionStateService.
//   - Disk-image containers (qcow2/VHD/VHDX/VMDK) have no switch — they
//     are compiled into every filesystem extension → "always available".
//   - Network & cloud schemes are all served by ONE File Provider
//     extension → a single on/off for the whole group.
//

import SwiftUI
import AppKit
import DiskJockeyLibrary

struct HomeView: View {
    let container: AppContainer
    /// Opens the "Add Network Drive" sheet — the binding for it lives
    /// in ContentView, so the action is passed down as a closure.
    var onAddNetworkDrive: () -> Void

    // Observed so the stat cards + capability columns stay live as disks
    // mount/unmount, mounts change, and extensions are toggled.
    @ObservedObject private var attachedDisks: AttachedDisksModel
    @ObservedObject private var directMountRegistry: DirectMountRegistry
    @ObservedObject private var rawDisks: RawDisksModel
    @ObservedObject private var extensionState: ExtensionStateService

    init(container: AppContainer, onAddNetworkDrive: @escaping () -> Void) {
        self.container = container
        self.onAddNetworkDrive = onAddNetworkDrive
        self.attachedDisks = container.attachedDisks
        self.directMountRegistry = container.directMountRegistry
        self.rawDisks = container.rawDisks
        self.extensionState = container.extensionState
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                stats
                capabilities
                quickActions
                Spacer(minLength: 0)
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        // Re-read extension state whenever Home appears (cheap; the
        // service also refreshes on app reactivation).
        .task { extensionState.refresh() }
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

    // MARK: - Capabilities

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: 24) {
            filesystemsSection
            containersSection
            networkSection
        }
    }

    // Filesystems: real per-extension Enabled / Disabled split.
    private var filesystemsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Filesystems")
            HStack(alignment: .top, spacing: 14) {
                CapabilityColumn(
                    title: "Enabled",
                    systemImage: "checkmark.circle.fill",
                    tint: .green,
                    items: enabledFilesystems
                )
                CapabilityColumn(
                    title: "Disabled",
                    systemImage: "slash.circle",
                    tint: .secondary,
                    items: disabledFilesystems,
                    onEnableTap: openExtensionSettings
                )
            }
            Text("Each filesystem is a separate macOS extension. Turn disabled ones on in System Settings → General → Login Items & Extensions → File System Extensions.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Disk image containers: no toggle — always available.
    private var containersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionTitle("Disk image containers")
                Spacer(minLength: 8)
                Label("Always available", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            }
            chipRow(["qcow2", "VHD", "VHDX", "VMDK"])
            Text("Built into every filesystem extension — nothing to enable.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // Network & cloud: one File Provider extension gates them all.
    private var networkSection: some View {
        let on = fileProviderEnabled
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionTitle("Network & cloud")
                Spacer(minLength: 8)
                Label(on ? "File Provider: on" : "File Provider: off",
                      systemImage: on ? "checkmark.circle.fill" : "slash.circle")
                    .font(.caption)
                    .foregroundStyle(on ? .green : .secondary)
                    .labelStyle(.titleAndIcon)
            }
            chipRow(["SMB", "FTP", "SFTP", "WebDAV", "S3",
                     "Dropbox", "Google Drive", "OneDrive"])
                .opacity(on ? 1.0 : 0.45)
            if on {
                Text("All served by one File Provider extension.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Button("Turn on in Settings…", action: openExtensionSettings)
                    .buttonStyle(.link)
                    .font(.caption)
            }
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

    // MARK: - Capability state

    private struct FilesystemDef {
        let name: String   // display name
        let key: String    // ExtensionStateService key / bundle suffix
    }

    private let filesystems = [
        FilesystemDef(name: "ext4", key: "ext4"),
        FilesystemDef(name: "NTFS", key: "ntfs"),
        FilesystemDef(name: "EROFS", key: "erofs"),
        FilesystemDef(name: "SquashFS", key: "squashfs"),
    ]

    private var enabledFilesystems: [String] {
        filesystems
            .filter { capabilityEnabled(key: $0.key, evidence: mountedFsKeys.contains($0.key)) }
            .map(\.name)
    }

    private var disabledFilesystems: [String] {
        filesystems
            .filter { !capabilityEnabled(key: $0.key, evidence: mountedFsKeys.contains($0.key)) }
            .map(\.name)
    }

    private var fileProviderEnabled: Bool {
        capabilityEnabled(key: "fileprovider", evidence: !directMountRegistry.mounts.isEmpty)
    }

    /// Trust pluginkit when it answered; otherwise fall back to
    /// functional evidence (a mounted volume / configured mount proves
    /// the extension is on even if the query was blocked).
    private func capabilityEnabled(key: String, evidence: Bool) -> Bool {
        switch extensionState.enabled[key] {
        case .some(let state): return state
        case .none:            return evidence
        }
    }

    /// fs keys with a currently-mounted volume of that type.
    private var mountedFsKeys: Set<String> {
        var keys = Set<String>()
        for disk in attachedDisks.disks {
            let fs = disk.fsType.lowercased()
            for key in ["ext4", "ntfs", "erofs", "squashfs"] where fs.contains(key) {
                keys.insert(key)
            }
        }
        return keys
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
    }

    private func chipRow(_ items: [String]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(items, id: \.self) { Chip(text: $0) }
        }
    }

    /// Open System Settings to where the File System / app-extension
    /// toggles live (Login Items & Extensions). We can deep-link to the
    /// pane but not to the specific subsheet, so the user taps "File
    /// System Extensions" there.
    private func openExtensionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
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

// MARK: - Capability column (Enabled / Disabled)

private struct CapabilityColumn: View {
    let title: String
    let systemImage: String
    let tint: Color
    let items: [String]
    /// When set and the column is non-empty, shows a link that opens
    /// System Settings so the user can enable the listed items.
    var onEnableTap: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text("\(items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }

            if items.isEmpty {
                Text("None")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(tint)
                            .frame(width: 6, height: 6)
                        Text(item)
                            .font(.body)
                        Spacer(minLength: 0)
                    }
                }
            }

            if let onEnableTap, !items.isEmpty {
                Button("Turn on in Settings…", action: onEnableTap)
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
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

// MARK: - Chip

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
