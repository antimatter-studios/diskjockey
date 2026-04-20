import FileProvider
import DiskJockeyLibrary

/// Structured-log surface for this extension. Every NSLog we previously
/// called only showed up in os_log / Console.app; using AppLog instead
/// funnels each line into `<app-group>/Logs/fileprovider.ndjson` which
/// the host app's LogTailService + in-app Log View already pick up,
/// alongside os_log for power users.
///
/// `internal` scope (no `private`) so the enumerator + direct-client
/// files in the same target share the same `log` instance — matches
/// the DiskJockeyEXT4 / DiskJockeyNTFS convention.
let log = AppLog(source: "fileprovider",
                 sinks: AppLog.defaultSinks(source: "fileprovider"))

/// Principal class for the FileProvider extension.
///
/// Routing model: every mount is *either* direct (libnetworkfs.a
/// linked in process) or XPC-backed (forwards to the Go backend over
/// NSXPCConnection). We figure out which at init time by checking for
/// a `StoredMountConfig` plist in the shared app group. If present →
/// direct client. If missing (or any load error) → fall back to the
/// existing XPC client.
///
/// The fallback is *critical*. Old mounts predating direct-mount
/// support won't have a config plist or keychain entry; they must keep
/// working on the XPC path. Don't remove it.
class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let mountID: String

    /// Stashed so we can build an `NSFileProviderManager(for:)` in
    /// `fetchContents` and resolve its `temporaryDirectoryURL()`. Writing
    /// fetched bytes into the extension's own sandbox `/tmp` works but
    /// `fileproviderd` (the system daemon that copies bytes to FP's
    /// permanent storage) can't always read across that sandbox
    /// boundary — result: eternal spinner in Finder. The per-domain
    /// manager's temp dir is shared between both sides.
    let domain: NSFileProviderDomain

    /// Per-mount tagged logger. Every line emitted through this logger
    /// carries `fields["mount"]=<mountID>`, so the host app's
    /// DirectMountRegistry can filter logs by domain for the per-mount
    /// log strip in the detail view. Module-level `log` (untagged) is
    /// still available for lines that aren't mount-specific.
    let mlog: TaggedLogger

    /// Always present; used for legacy mounts + as a fallback when the
    /// direct-client init fails for any reason.
    let xpcClient = FileProviderXPCClient()

    /// Present only when a StoredMountConfig + keychain entry exist for
    /// this domain. Read-only after init — FileProvider may hand us
    /// concurrent op requests.
    let directClient: FileProviderDirectClient?

    required init(domain: NSFileProviderDomain) {
        // The domain identifier encodes either the backend mount ID
        // (legacy: "3") or a UUID (direct mounts). The value is opaque
        // to the routing layer — it's just a lookup key.
        self.domain = domain
        self.mountID = domain.identifier.rawValue
        self.mlog = TaggedLogger(
            log,
            fields: ["mount": mountID],
            kind: "fileprovider.mount"
        )

        // Try to build a direct client. If the config/keychain isn't
        // there, this mount hasn't been migrated — fall back to XPC.
        let store = MountConfigStore()
        if store.exists(domainID: mountID) {
            do {
                self.directClient = try FileProviderDirectClient(domainID: mountID,
                                                                 log: mlog)
                self.mlog.info("direct client ready")
            } catch {
                self.mlog.error("direct-client init failed: \(error); using XPC fallback")
                self.directClient = nil
            }
        } else {
            self.directClient = nil
            self.mlog.info("no direct config; using XPC")
        }

        super.init()
        self.mlog.info("Initialized")
        // libnetworkfs smoke-test log — confirms the combined archive
        // was actually linked into the extension. Harmless on startup
        // even when no direct mount exists.
        self.mlog.info("libnetworkfs version: \(NetworkFSDriver.libraryVersion())")
    }

    func invalidate() {
        self.mlog.info("Invalidating extension for mount: \(mountID)")
        directClient?.disconnect()
    }

    // MARK: - Item Resolution

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        self.mlog.info("item(for: \(identifier.rawValue))")

        // System containers are synthetic — no backend call needed
        if identifier == .rootContainer {
            let rootItem = FileProviderItem(
                info: DiskJockeyFileItem(name: "", size: 0, isDirectory: true),
                parentPath: ""
            )
            completionHandler(rootItem, nil)
            return Progress()
        }

        if identifier == .trashContainer {
            let trashItem = FileProviderItem(
                info: DiskJockeyFileItem(name: ".Trash", size: 0, isDirectory: true),
                parentPath: "/"
            )
            completionHandler(trashItem, nil)
            return Progress()
        }

        if identifier == .workingSet {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }

        let path = extractPath(from: identifier)

        // Direct path: libnetworkfs stat.
        if let direct = directClient {
            itemViaDirect(direct: direct, path: path, completionHandler: completionHandler)
            return Progress()
        }

        // XPC fallback
        xpcClient.stat(mountID: mountID, path: path) { response in
            guard let response = response else {
                completionHandler(nil, NSFileProviderError(.serverUnreachable))
                return
            }

            if case .error(let err) = response.responseType {
                self.mlog.error("stat error: \(err.message)")
                completionHandler(nil, NSFileProviderError(.noSuchItem))
                return
            }

            guard case .stat(let statResp) = response.responseType else {
                completionHandler(nil, NSFileProviderError(.serverUnreachable))
                return
            }

            let parentPath = (path as NSString).deletingLastPathComponent
            let item = FileProviderItem(
                info: DiskJockeyFileItem(
                    name: statResp.file.name,
                    size: statResp.file.size,
                    isDirectory: statResp.file.isDirectory
                ),
                parentPath: parentPath
            )
            completionHandler(item, nil)
        }

        return Progress()
    }

    /// Direct-path implementation of `item(for:)`. libnetworkfs stat
    /// is synchronous; we run it off the calling thread so we don't
    /// block the FileProvider-owned queue.
    private func itemViaDirect(direct: FileProviderDirectClient,
                               path: String,
                               completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let info = try direct.stat(path: path)
                let parentPath = (path as NSString).deletingLastPathComponent
                let item = FileProviderItem(info: info.toFileItem(), parentPath: parentPath)
                completionHandler(item, nil)
            } catch {
                self.mlog.error("direct stat(\(path)) failed: \("\(error)")")
                completionHandler(nil, Self.mapError(error))
            }
        }
    }

    // MARK: - File Contents

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let path = extractPath(from: itemIdentifier)
        self.mlog.info("fetchContents for: \(path)")

        if let direct = directClient {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // Fetch first, then derive metadata from what we
                    // already know. Earlier we did stat-then-fetch to
                    // guarantee real metadata, but stat breaks on FTP
                    // servers that don't implement MLST/MDTM (the
                    // `jlaffaye/ftp` GetEntry path) — vsftpd returns
                    // `502 Command not implemented` and the whole
                    // fetch fails even though RETR would work. We can
                    // still produce real metadata without the server
                    // round-trip:
                    //
                    //   name        ← last component of the path
                    //   size        ← size of the temp file on disk
                    //                 after RETR completes
                    //   isDirectory ← false (fetchContents is only
                    //                 ever called on files)
                    //
                    // That's just as accurate as stat, doesn't
                    // fabricate anything, and doesn't depend on
                    // optional FTP commands.
                    //
                    // Write into NSFileProviderManager's temp dir (not
                    // `FileManager.default.temporaryDirectory`, which
                    // lives inside the extension's sandbox container
                    // and isn't always readable from the fileproviderd
                    // daemon — cause of the "file downloaded but
                    // Finder stays spinning" bug). The FP-managed dir
                    // is shared between the extension + daemon.
                    let url: URL
                    if let manager = NSFileProviderManager(for: self.domain) {
                        let dir = try manager.temporaryDirectoryURL()
                        url = dir.appendingPathComponent(UUID().uuidString)
                    } else {
                        // Fallback: shouldn't happen since the extension
                        // IS running for this domain, but if FP can't
                        // give us a manager, don't crash — use our own
                        // sandbox temp and accept the spinner risk.
                        url = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                    }
                    try direct.fetchFile(path: path, to: url)
                    let parentPath = (path as NSString).deletingLastPathComponent
                    let name = (path as NSString).lastPathComponent
                    let size: Int64
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                       let n = attrs[.size] as? Int64 {
                        size = n
                    } else if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                              let n = attrs[.size] as? NSNumber {
                        size = n.int64Value
                    } else {
                        size = 0
                    }
                    let item = FileProviderItem(
                        info: DiskJockeyFileItem(name: name, size: size, isDirectory: false),
                        parentPath: parentPath
                    )
                    completionHandler(url, item, nil)
                } catch {
                    self.mlog.error("direct fetch(\(path)) failed: \("\(error)")")
                    completionHandler(nil, nil, Self.mapError(error))
                }
            }
            return Progress()
        }

        // XPC fallback — same hard-fail rule: stat before returning
        // an item. Two round-trips is slower than one but correctness
        // wins over speed on a filesystem driver.
        xpcClient.readFile(mountID: mountID, path: path) { response in
            guard let response = response else {
                completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
                return
            }

            if case .error(let err) = response.responseType {
                self.mlog.error("read error: \(err.message)")
                completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                return
            }

            guard case .read(let readResp) = response.responseType else {
                completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
                return
            }

            self.mlog.info("fetchContents received \(readResp.data.count) bytes for \(path)")

            // Write data to a temporary file
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            do {
                try readResp.data.write(to: tempURL)
                self.mlog.info("Wrote \(readResp.data.count) bytes to \(tempURL.path)")
            } catch {
                self.mlog.error("Failed to write temp file: \(error.localizedDescription)")
                completionHandler(nil, nil, error)
                return
            }

            // Stat the path so we can return an item with real
            // metadata. Hard fail if stat fails.
            self.xpcClient.stat(mountID: self.mountID, path: path) { statResp in
                guard let statResp = statResp,
                      case .stat(let s) = statResp.responseType else {
                    self.mlog.error("post-fetch stat failed; hard-failing fetchContents")
                    completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                    return
                }
                let parentPath = (path as NSString).deletingLastPathComponent
                let item = FileProviderItem(
                    info: DiskJockeyFileItem(
                        name: s.file.name,
                        size: s.file.size,
                        isDirectory: s.file.isDirectory
                    ),
                    parentPath: parentPath
                )
                completionHandler(tempURL, item, nil)
            }
        }

        return Progress()
    }

    // MARK: - Write Operations (not implemented — read-only MVP)

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:]))
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        // Read-only: return the item unchanged, no error
        completionHandler(item, [], false, nil)
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:]))
        return Progress()
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        self.mlog.info("Creating enumerator for: \(containerItemIdentifier.rawValue)")
        return FileProviderEnumerator(
            enumeratedItemIdentifier: containerItemIdentifier,
            mountID: mountID,
            xpcClient: xpcClient,
            directClient: directClient,
            mlog: mlog
        )
    }

    // MARK: - Helpers

    /// Extract the filesystem path from a File Provider item identifier.
    /// "item-/path/to/file.txt" → "/path/to/file.txt"
    private func extractPath(from identifier: NSFileProviderItemIdentifier) -> String {
        let raw = identifier.rawValue
        guard raw.hasPrefix("item-") else { return "/" }
        return String(raw.dropFirst("item-".count))
    }

    /// Translate a Swift-layer error into the NSFileProviderError cases
    /// Finder knows how to render. Kept static so the Enumerator can
    /// reuse it.
    static func mapError(_ error: Error) -> Error {
        switch error {
        case let c as FileProviderDirectClientError:
            switch c {
            case .missingConfig, .missingPassword:
                // Config/keychain missing = the user deleted the mount
                // while Finder was still holding a reference. Treat as
                // "no such item" so the UI prunes the stale entry.
                return NSFileProviderError(.noSuchItem)
            case .driver(let d):
                return mapDriverError(d)
            }
        case let d as NetworkFSDriverError:
            return mapDriverError(d)
        default:
            return error
        }
    }

    private static func mapDriverError(_ d: NetworkFSDriverError) -> Error {
        switch d {
        case .mountFailed, .unmountFailed:
            return NSFileProviderError(.serverUnreachable)
        case .operationFailed(_, _, _, let message):
            // "no such file" / "permission denied" across every
            // protocol land here with the underlying server's error
            // text. Parse-free heuristic: anything mentioning
            // "no such" / "not found" / "does not exist" →
            // noSuchItem; else generic unreachable.
            let lower = message.lowercased()
            if lower.contains("no such") || lower.contains("not found") || lower.contains("does not exist") {
                return NSFileProviderError(.noSuchItem)
            }
            return NSFileProviderError(.serverUnreachable)
        case .readFailed:
            return NSFileProviderError(.noSuchItem)
        case .decodeFailed, .invalidConfig, .tempFileFailed:
            return NSFileProviderError(.serverUnreachable)
        }
    }
}
