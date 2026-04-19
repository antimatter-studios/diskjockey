import Foundation

/// Metadata for a single vendored library, parsed from a key=value VERSION manifest
/// that ships in the app bundle under `Resources/vendor-versions/`.
public struct VendoredLibraryInfo: Identifiable, Hashable {
    public enum RefType: String {
        case branch
        case tag
        case detached
        case unknown
    }

    public let id: String           // lib name (also used as sort key)
    public let name: String
    public let source: String       // remote URL
    public let ref: String
    public let refType: RefType
    public let commit: String       // full commit hash
    public let shortCommit: String
    public let describe: String
    public let isDirty: Bool
    public let builtAt: Date?       // parsed ISO8601

    public init(
        id: String,
        name: String,
        source: String,
        ref: String,
        refType: RefType,
        commit: String,
        shortCommit: String,
        describe: String,
        isDirty: Bool,
        builtAt: Date?
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.ref = ref
        self.refType = refType
        self.commit = commit
        self.shortCommit = shortCommit
        self.describe = describe
        self.isDirty = isDirty
        self.builtAt = builtAt
    }

    // MARK: - Parsing

    /// Parse a key=value manifest. Blank lines and `#` comments are ignored.
    /// Returns `nil` if required keys (`lib`, `commit`) are missing.
    public static func parse(_ text: String) -> VendoredLibraryInfo? {
        var kv: [String: String] = [:]
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                kv[key] = value
            }
        }

        guard let lib = kv["lib"], !lib.isEmpty else { return nil }
        guard let commit = kv["commit"], !commit.isEmpty else { return nil }

        let refTypeRaw = kv["ref_type"] ?? ""
        let refType = RefType(rawValue: refTypeRaw) ?? .unknown

        let isDirty = (kv["dirty"]?.lowercased() == "true")

        let shortCommit: String = {
            if let s = kv["short_commit"], !s.isEmpty { return s }
            return String(commit.prefix(7))
        }()

        let describe = kv["describe"] ?? shortCommit
        let ref = kv["ref"] ?? ""
        let source = kv["source"] ?? ""

        var builtAt: Date? = nil
        if let builtAtStr = kv["built_at"], !builtAtStr.isEmpty {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            builtAt = f.date(from: builtAtStr)
        }

        return VendoredLibraryInfo(
            id: lib,
            name: lib,
            source: source,
            ref: ref,
            refType: refType,
            commit: commit,
            shortCommit: shortCommit,
            describe: describe,
            isDirty: isDirty,
            builtAt: builtAt
        )
    }

    // MARK: - Loading

    /// Discover and parse every vendor manifest shipped in the app bundle.
    /// Preferred location: `Resources/vendor-versions/*.txt`.
    /// Fallback: any `VERSION*.txt` at the resources root.
    public static func loadAll() -> [VendoredLibraryInfo] {
        let fm = FileManager.default
        var urls: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            let vendorDir = resourceURL.appendingPathComponent("vendor-versions", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: vendorDir.path, isDirectory: &isDir), isDir.boolValue {
                if let enumerated = try? fm.contentsOfDirectory(
                    at: vendorDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) {
                    urls = enumerated.filter { $0.pathExtension.lowercased() == "txt" }
                }
            }

            if urls.isEmpty {
                // Fallback: scan resources root for VERSION*.txt
                if let enumerated = try? fm.contentsOfDirectory(
                    at: resourceURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) {
                    urls = enumerated.filter { url in
                        let name = url.lastPathComponent
                        return name.hasPrefix("VERSION") && name.lowercased().hasSuffix(".txt")
                    }
                }
            }
        }

        var infos: [VendoredLibraryInfo] = []
        for url in urls {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                if let info = parse(text) {
                    infos.append(info)
                } else {
                    print("[VendoredLibraryInfo] skipping \(url.lastPathComponent): missing required keys")
                }
            } catch {
                print("[VendoredLibraryInfo] skipping \(url.lastPathComponent): \(error)")
            }
        }

        return infos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
