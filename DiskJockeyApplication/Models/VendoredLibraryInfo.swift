import Foundation

/// Metadata for a single vendored library, parsed from a VERSION manifest that
/// ships in the app bundle under `Resources/vendor-versions/`: a sibling's
/// key=value manifest, or a filesystem bundle's list of resolved crates.
public struct VendoredLibraryInfo: Identifiable, Hashable {
    /// One crate a filesystem bundle resolved, as `build-bundles.sh` lists it.
    public struct ResolvedCrate: Hashable {
        public let name: String
        public let version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

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
    public let commitDate: Date?    // parsed ISO8601 — when the commit was made upstream
    /// The crates a filesystem bundle resolved; empty for a sibling.
    public let crates: [ResolvedCrate]

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
        commitDate: Date?,
        crates: [ResolvedCrate] = []
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
        self.commitDate = commitDate
        self.crates = crates
    }

    // MARK: - Parsing

    /// Parse the manifest `text` the build copied in as `fileName`: a
    /// key=value manifest (``parse(_:)``), or else a filesystem bundle's.
    public static func parse(_ text: String, fileName: String) -> VendoredLibraryInfo? {
        parse(text) ?? parseBundle(text, fileName: fileName)
    }

    /// The header `scripts/build-bundles.sh` writes above a bundle's crates.
    static let bundleHeader = "bundle resolved crates"

    /// A filesystem bundle's manifest (diskjockey#347): the header, then one
    /// `name version` line per crate the bundle resolved. The bundle's name
    /// is only in the file name the build gives it, `bundle_<fs>-VERSION.txt`,
    /// and it is shown as its crate is named, `dj-<fs>-bundle`, with its
    /// driver's version. Nil when the header or every crate is missing.
    static func parseBundle(_ text: String, fileName: String) -> VendoredLibraryInfo? {
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let header = lines.first, header.hasPrefix(bundleHeader) else { return nil }
        let crates: [ResolvedCrate] = lines.dropFirst().compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }
            return ResolvedCrate(name: String(parts[0]), version: String(parts[1]))
        }
        guard !crates.isEmpty else { return nil }
        let stem = fileName.components(separatedBy: "-VERSION").first ?? fileName
        let fs = stem.hasPrefix("bundle_") ? String(stem.dropFirst("bundle_".count)) : stem
        let name = "dj-\(fs)-bundle"
        let driver = crates.first { $0.name.hasSuffix("-\(fs)") }
        return VendoredLibraryInfo(
            id: name,
            name: name,
            source: "crates.io",
            ref: "",
            refType: .unknown,
            commit: "",
            shortCommit: "—",
            describe: driver?.version ?? "\(crates.count) crates",
            isDirty: false,
            commitDate: nil,
            crates: crates
        )
    }

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

        var commitDate: Date? = nil
        // Accept either the current `commit_date` key or the legacy `built_at`
        // key so stale manifests don't silently lose the date.
        let dateStr = kv["commit_date"] ?? kv["built_at"] ?? ""
        if !dateStr.isEmpty {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            commitDate = f.date(from: dateStr)
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
            commitDate: commitDate
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
                if let info = parse(text, fileName: url.lastPathComponent) {
                    infos.append(info)
                } else {
                    print("[VendoredLibraryInfo] skipping \(url.lastPathComponent): neither a key=value nor a bundle manifest")
                }
            } catch {
                print("[VendoredLibraryInfo] skipping \(url.lastPathComponent): \(error)")
            }
        }

        return infos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
