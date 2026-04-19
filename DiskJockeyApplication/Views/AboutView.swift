import SwiftUI
import AppKit

struct AboutView: View {
    private let libraries: [VendoredLibraryInfo] = VendoredLibraryInfo.loadAll()

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

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
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
                }
                Spacer()
            }

            Divider()

            // Vendored libraries section
            Text("Vendored libraries")
                .font(.headline)

            if libraries.isEmpty {
                Text("No vendor manifests found")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(libraries) { lib in
                        libraryRow(lib)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .textSelection(.enabled)
        .frame(minWidth: 440, maxWidth: 440, minHeight: 360, alignment: .top)
    }

    @ViewBuilder
    private func libraryRow(_ lib: VendoredLibraryInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(lib.name)
                        .font(.body)
                        .bold()
                    if lib.isDirty {
                        Text("dirty")
                            .font(.caption2)
                            .bold()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.red)
                            )
                    }
                }
                HStack(spacing: 4) {
                    Text(lib.ref)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(lib.shortCommit)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let builtAt = lib.builtAt {
                Text(Self.shortDateFormatter.string(from: builtAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
