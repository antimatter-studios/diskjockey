//
// AboutPageView.swift — the full-window About page (sidebar → About).
//
// Carries the project description, an architecture summary, the
// complete list of vendored library versions, and license / source
// details. This is the roomy presentation of the vendored-library
// information that the cramped menu-bar "About DiskJockey" window
// used to show; that window now stays a minimal standard about box.
//

import SwiftUI
import AppKit
import DiskJockeyLibrary

struct AboutPageView: View {
    private let libraries: [VendoredLibraryInfo] = VendoredLibraryInfo.loadAll()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                about
                architecture
                librariesSection
                footer
                Spacer(minLength: 0)
            }
            .padding(32)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .textSelection(.enabled)
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
            VStack(alignment: .leading, spacing: 5) {
                Text(appName)
                    .font(.system(size: 28, weight: .bold))
                Text("Version \(appVersion) (\(appBuild))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let built = appBuildDate {
                    Text("Built \(Self.buildTimestampFormatter.string(from: built))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - About

    private var about: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("About")
            Text("DiskJockey mounts remote storage and disk images as native Finder volumes. It unifies three categories of filesystem — network and cloud storage, block-device disk images, and local passthrough — behind one consistent Finder experience, without kernel extensions and without bundling third-party userspace tooling.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Architecture

    private var architecture: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("How it works")
            ArchPoint(
                systemImage: "internaldrive",
                title: "Block devices via FSKit",
                detail: "Disk images and on-disk filesystems mount through FSKit extensions (macOS 15+), each backed by a pure-Rust driver linked directly into a per-filesystem extension."
            )
            ArchPoint(
                systemImage: "network",
                title: "Network & cloud via File Provider",
                detail: "Remote endpoints (SMB, FTP, SFTP, WebDAV, S3, and cloud drives) are served by a File Provider extension — no background daemon, no privileged helper."
            )
            ArchPoint(
                systemImage: "cpu",
                title: "Apple Silicon, sandbox-friendly",
                detail: "Built for arm64 on macOS 15.5+. The app is sandboxed; permissions are scoped to what you grant."
            )
        }
    }

    // MARK: - Vendored libraries

    private var librariesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Vendored libraries")

            if libraries.isEmpty {
                Text("No vendor manifests found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline,
                     horizontalSpacing: 18,
                     verticalSpacing: 0) {
                    GridRow {
                        columnHeader("Library")
                        columnHeader("Version")
                        columnHeader("Commit")
                        columnHeader("Date")
                    }
                    Divider().gridCellColumns(4)
                    ForEach(libraries) { lib in
                        libraryRow(lib)
                        if lib.id != libraries.last?.id {
                            Divider().gridCellColumns(4).opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func libraryRow(_ lib: VendoredLibraryInfo) -> some View {
        GridRow {
            HStack(spacing: 6) {
                Text(lib.name)
                    .font(.body.weight(.medium))
                if lib.isDirty {
                    Text("dirty")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.red))
                }
            }
            Text(versionLabel(lib))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(lib.shortCommit)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(lib.commitDate.map(Self.shortDateFormatter.string(from:)) ?? "—")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .padding(.bottom, 4)
            HStack(spacing: 6) {
                Text("MIT License · © 2025 Christopher Thomas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Link("Source on GitHub",
                     destination: URL(string: "https://github.com/antimatter-studios/diskjockey")!)
                    .font(.caption)
            }
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
    }

    private func columnHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.bottom, 6)
    }

    /// Prefer a tag-like `describe` ("v0.3.3"); fall back to the raw ref.
    private func versionLabel(_ lib: VendoredLibraryInfo) -> String {
        if !lib.describe.isEmpty, lib.describe != lib.shortCommit { return lib.describe }
        if !lib.ref.isEmpty { return lib.ref }
        return lib.shortCommit
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

    /// mtime of the app's main executable — Xcode rewrites it on every
    /// build, so this tracks the last compile time within ~seconds.
    private var appBuildDate: Date? {
        guard let exec = Bundle.main.executableURL else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: exec.path)
        return attrs?[.modificationDate] as? Date
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let buildTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

// MARK: - Architecture point

private struct ArchPoint: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
