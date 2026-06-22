import SwiftUI
import AppKit

struct AboutView: View {
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

    /// mtime of the app's main executable — Xcode re-signs/rewrites it on every
    /// build, so this tracks the last compile time within ~seconds.
    private var appBuildDate: Date? {
        guard let exec = Bundle.main.executableURL else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: exec.path)
        return attrs?[.modificationDate] as? Date
    }

    private static let buildTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 16) {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(appName)
                        .font(.title2)
                        .bold()
                    Text("Version \(appVersion) (\(appBuild))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let built = appBuildDate {
                        Text("Built \(Self.buildTimestampFormatter.string(from: built))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }

            Text("Mount remote storage and disk images as native Finder volumes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Library versions and project details are on the About page in the main window.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(20)
        .textSelection(.enabled)
        .frame(width: 380, alignment: .leading)
    }
}
