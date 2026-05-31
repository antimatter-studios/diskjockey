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
/// Every mount is direct: `libnetworkfs.a` is linked into this
/// extension, and a `StoredMountConfig` plist (shared app-group
/// container) + keychain entry identify what to mount. If the config
/// or password is missing — e.g. the user removed the mount while
/// Finder was still holding a reference — we return NSFileProviderError
/// per-op rather than crashing.
class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing {
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

    /// Handle on `libnetworkfs`. `nil` when config/keychain was missing
    /// at init — every operation then returns `.noSuchItem` so Finder
    /// prunes the stale domain cleanly.
    let directClient: FileProviderDirectClient?

    /// Per-mount I/O counter aggregator. Emits `io.stats` events tagged
    /// with `fields["mount"]=<mountID>` (inherited from `mlog`). The
    /// host app's DirectMountRegistry routes them into the per-mount
    /// detail view. Counters reset on each FileProvider extension
    /// respawn — this is "live activity" not "lifetime totals".
    let stats: IOStatsCollector

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.mountID = domain.identifier.rawValue
        self.mlog = TaggedLogger(
            log,
            fields: ["mount": mountID],
            kind: "fileprovider.mount"
        )

        do {
            self.directClient = try FileProviderDirectClient(
                domainID: mountID, log: mlog
            )
            self.mlog.info("direct client ready")
        } catch {
            // Config or keychain missing. This is not fatal — the
            // per-op methods below check for `nil` and fail with
            // noSuchItem. Finder will then prune the domain on its
            // next refresh. We also surface a `mount.error` so the
            // host app's banner explains why the mount stopped
            // working instead of the user just seeing an empty
            // folder.
            self.mlog.error("direct-client init failed: \(error)")
            emitMountError(mlog: mlog, op: "init", path: nil, error: error)
            self.directClient = nil
        }

        // The shared IOStatsRecorder (in DiskJockeyLibrary) is generic
        // — it doesn't know about NetworkFSDriver. We inject:
        //   • emit: the per-extension logger so AppLog stays local,
        //   • preflush: the Go-side transport counter overlay (every
        //     tick we pull the authoritative byte/op totals from
        //     networkfs_get_stats and write them onto the snapshot
        //     before the duplicate-suppression check).
        let goMountID = FileProviderDirectClient.mountID(for: mountID)
        let mlogCopy = mlog
        self.stats = IOStatsRecorder(
            label: mountID,
            emit: { fields in
                mlogCopy.event(kind: "io.stats", fields: fields)
            },
            preflush: { counters in
                let go = NetworkFSDriver.getStats(mountID: goMountID)
                counters.bytesRead = go.bytesRead
                counters.bytesWritten = go.bytesWritten
                counters.opsRead = go.opsRead
                counters.opsWritten = go.opsWritten
            }
        )

        super.init()
        self.mlog.info("Initialized")
        // Begin 1 Hz `io.stats` heartbeats — self-suppressing on idle.
        // Stopped in `invalidate()`.
        self.stats.start()
        // libnetworkfs smoke-test log — confirms the combined archive
        // was actually linked into the extension.
        self.mlog.info("libnetworkfs version: \(NetworkFSDriver.libraryVersion())")
    }

    func invalidate() {
        self.mlog.info("Invalidating extension for mount: \(mountID)")
        // Final stats flush before sinks tear down with the extension.
        stats.stop()
        directClient?.disconnect()
    }

    // MARK: - Item Resolution

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        self.mlog.info("item(for: \(identifier.rawValue))")

        // System containers are synthetic — no network call needed.
        if identifier == .rootContainer {
            let rootItem = FileProviderItem(
                info: DiskJockeyFileItem(name: "", size: 0, isDirectory: true),
                parentPath: ""
            )
            completionHandler(rootItem, nil)
            return Progress()
        }

        if identifier == .trashContainer {
            // We don't implement Trash — return noSuchItem like
            // workingSet below. Returning a synthesized FileProviderItem
            // here was wrong: its `itemIdentifier` came back as
            // `item-/.Trash` not `.trashContainer`, which fileproviderd
            // rejects with `itemMismatch` and then invalidates the
            // whole extension session — at which point Finder shows
            // nothing for the mount even though enumeration succeeded.
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }

        if identifier == .workingSet {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }

        guard let direct = directClient else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }

        let path = extractPath(from: identifier)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let info = try direct.stat(path: path)
                let parentPath = (path as NSString).deletingLastPathComponent
                let item = FileProviderItem(info: info.toFileItem(), parentPath: parentPath)
                completionHandler(item, nil)
            } catch {
                self.mlog.error("direct stat(\(path)) failed: \("\(error)")")
                // DirectClient emits `mount.error` for its own throws;
                // only surface here when the error came from somewhere
                // else (defensive — every reachable error today is a
                // FileProviderDirectClientError, but future refactors
                // may add untyped throws).
                if !(error is FileProviderDirectClientError) {
                    emitMountError(mlog: self.mlog, op: "stat",
                                   path: path, error: error)
                }
                completionHandler(nil, Self.mapError(error))
            }
        }

        return Progress()
    }

    // MARK: - File Contents

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let path = extractPath(from: itemIdentifier)
        self.mlog.info("fetchContents for: \(path)")

        guard let direct = directClient else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // Bracket the fetch so we can record bytes_read +
            // read_latency for the partition's I/O stats panel. Bytes
            // are derived from the on-disk size of the temp file
            // produced by RETR — same source we hand back to FP.
            let t0 = monotonicNanos()
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
                self.stats.recordRead(bytes: Int(size),
                                      latencyNs: monotonicNanos() &- t0,
                                      error: false)
                let item = FileProviderItem(
                    info: DiskJockeyFileItem(name: name, size: size, isDirectory: false),
                    parentPath: parentPath
                )
                completionHandler(url, item, nil)
            } catch {
                self.stats.recordRead(bytes: 0,
                                      latencyNs: monotonicNanos() &- t0,
                                      error: true)
                self.mlog.error("direct fetch(\(path)) failed: \("\(error)")")
                // DirectClient emits `mount.error` for its own throws;
                // surface anything else (e.g. temp-dir creation
                // failures, FP manager unavailable).
                if !(error is FileProviderDirectClientError) {
                    emitMountError(mlog: self.mlog, op: "fetchFile",
                                   path: path, error: error)
                }
                completionHandler(nil, nil, Self.mapError(error))
            }
        }

        return Progress()
    }

    // MARK: - Thumbnails

    /// Finder asks for thumbnails when displaying a folder so the
    /// user sees image previews instead of generic icons. We honour
    /// it only for drivers that implement the Go-side `Thumbnailer`
    /// interface (today: Dropbox), and only when the per-mount
    /// `fetchThumbnails` toggle is on AND the active network path
    /// isn't metered (cellular / Low Data Mode).
    ///
    /// Each thumbnail goes through `ThumbnailCache` first — Finder
    /// re-asks the same identifiers repeatedly (folder reopen, scroll
    /// back, icon-size change), so without the cache we'd burn the
    /// user's data plan on a folder of photos.
    ///
    /// We always invoke `perThumbnailCompletionHandler` for every
    /// requested identifier (even on skip / error, with a `nil` data
    /// payload — Finder treats that as "fall back to generic icon").
    ///
    /// Marked `@objc` because `fetchThumbnails(...)` is declared
    /// `@objc optional` on `NSFileProviderReplicatedExtension`.
    /// Without the marker, Swift doesn't expose our override to the
    /// Obj-C runtime — fileproviderd's `respondsToSelector:` check
    /// then returns false and the system falls back to QuickLook
    /// downloading the full file to generate a thumbnail locally,
    /// which on cloud-only items returns `(null)` and the user sees
    /// generic icons forever.
    @objc
    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier],
                         requestedSize size: CGSize,
                         perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
                         completionHandler: @escaping (Error?) -> Void) -> Progress {
        // Long edge in pixels — the FP API hands us points; we fetch
        // the smallest provider bucket >= long edge, then cache by
        // that bucket so similar requests share a row.
        let sizePx = Int(max(size.width, size.height).rounded(.up))
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        mlog.info("fetchThumbnails called count=\(itemIdentifiers.count) sizePx=\(sizePx)")

        switch thumbnailPolicy() {
        case .skip(let reason):
            mlog.info("thumbnails skipped (\(reason)) count=\(itemIdentifiers.count)")
            skipAllThumbnails(itemIdentifiers, progress: progress,
                              perThumbnail: perThumbnailCompletionHandler, completion: completionHandler)
            return progress
        case .fetch:
            break
        }

        guard let direct = directClient else {
            // Mount configuration is missing; let Finder fall back to generic icons.
            skipAllThumbnails(itemIdentifiers, progress: progress,
                              perThumbnail: perThumbnailCompletionHandler, completion: completionHandler)
            return progress
        }

        fetchThumbnailsInBackground(
            items: itemIdentifiers, sizePx: sizePx, direct: direct,
            progress: progress,
            perThumbnail: perThumbnailCompletionHandler,
            completion: completionHandler
        )
        return progress
    }

    private func skipAllThumbnails(
        _ ids: [NSFileProviderItemIdentifier],
        progress: Progress,
        perThumbnail: (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
        completion: (Error?) -> Void
    ) {
        for id in ids {
            perThumbnail(id, nil, nil)
            progress.completedUnitCount += 1
        }
        completion(nil)
    }

    private func fetchThumbnailsInBackground(
        items: [NSFileProviderItemIdentifier],
        sizePx: Int,
        direct: FileProviderDirectClient,
        progress: Progress,
        perThumbnail: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        let mountID = self.mountID
        let log = self.mlog
        DispatchQueue.global(qos: .userInitiated).async {
            var hits = 0; var fetches = 0; var fails = 0
            for id in items {
                let path = self.extractPath(from: id)
                if let cached = ThumbnailCache.shared.get(mountID: mountID, path: path, sizePx: sizePx) {
                    perThumbnail(id, cached, nil)
                    progress.completedUnitCount += 1
                    hits += 1
                    continue
                }
                do {
                    let data = try direct.fetchThumbnail(path: path, sizePx: sizePx)
                    ThumbnailCache.shared.put(mountID: mountID, path: path, sizePx: sizePx, data: data)
                    perThumbnail(id, data, nil)
                    fetches += 1
                } catch {
                    // Drivers without thumbnail support (rc=2) and per-file fetch failures
                    // both land here — Finder gets nil data, no surfaced error.
                    log.debug("thumbnail(\(path)) skipped: \("\(error)")")
                    perThumbnail(id, nil, nil)
                    fails += 1
                }
                progress.completedUnitCount += 1
            }
            log.info("fetchThumbnails done: cache=\(hits) fetched=\(fetches) failed=\(fails)")
            completion(nil)
        }
    }

    /// Decide whether to attempt thumbnail fetches for this mount on
    /// the current network path. Defers to the protocol-agnostic
    /// `FileProviderDirectClient.shouldFetchThumbnails` so the same
    /// gates (per-mount `MountPolicy` + `NetworkPathMonitor`) apply
    /// to Finder-driven and pre-warm fetches uniformly.
    private func thumbnailPolicy() -> ThumbnailPolicy {
        guard let direct = directClient else {
            return .skip(reason: "no direct client")
        }
        if !direct.policy.fetchThumbnails {
            return .skip(reason: "per-mount toggle off")
        }
        if NetworkPathMonitor.shared.isExpensiveOrConstrained {
            return .skip(reason: "expensive/constrained network")
        }
        return .fetch
    }

    private enum ThumbnailPolicy {
        case fetch
        case skip(reason: String)
    }

    // MARK: - Write Operations

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        guard let direct = directClient else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return Progress()
        }

        let parentPath = extractPath(from: itemTemplate.parentItemIdentifier)
        let filename = itemTemplate.filename
        let newPath = joinPath(parentPath, filename)
        let isFolder = (itemTemplate.contentType == .folder)
        self.mlog.info("createItem(\(newPath)) folder=\(isFolder)")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if isFolder {
                    try direct.mkdir(path: newPath)
                } else {
                    guard let src = url else {
                        completionHandler(nil, [], false, NSError(
                            domain: NSCocoaErrorDomain,
                            code: NSFeatureUnsupportedError,
                            userInfo: [NSLocalizedDescriptionKey: "createItem: missing contents URL"]
                        ))
                        return
                    }
                    let data = try Data(contentsOf: src)
                    try direct.writeFile(path: newPath, data: data)
                }
                let info = try direct.stat(path: newPath)
                let item = FileProviderItem(info: info.toFileItem(), parentPath: parentPath)
                completionHandler(item, [], false, nil)
                if let manager = NSFileProviderManager(for: self.domain) {
                    manager.signalEnumerator(for: itemTemplate.parentItemIdentifier) { _ in }
                }
            } catch {
                self.mlog.error("createItem(\(newPath)) failed: \("\(error)")")
                if !(error is FileProviderDirectClientError) {
                    emitMountError(mlog: self.mlog, op: isFolder ? "mkdir" : "writefile",
                                   path: newPath, error: error)
                }
                completionHandler(nil, [], false, Self.mapError(error))
            }
        }
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        guard let direct = directClient else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return Progress()
        }

        // Old path comes from the existing identifier ("item-<oldpath>");
        // new path is rebuilt from the desired-state item's parent + filename.
        let oldPath = extractPath(from: item.itemIdentifier)
        let oldParentIdentifier = NSFileProviderItemIdentifier(
            "item-" + ((oldPath as NSString).deletingLastPathComponent)
        )
        let newParentPath = extractPath(from: item.parentItemIdentifier)
        let newPath = joinPath(newParentPath, item.filename)
        let renamed = (changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier))
            && oldPath != newPath
        let updateContents = changedFields.contains(.contents) && newContents != nil

        self.mlog.info("modifyItem old=\(oldPath) new=\(newPath) renamed=\(renamed) updateContents=\(updateContents)")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if renamed {
                    try direct.renameItem(from: oldPath, to: newPath)
                }
                if updateContents, let src = newContents {
                    let data = try Data(contentsOf: src)
                    try direct.writeFile(path: newPath, data: data)
                }
                let info = try direct.stat(path: newPath)
                let parentPath = (newPath as NSString).deletingLastPathComponent
                let resultItem = FileProviderItem(info: info.toFileItem(), parentPath: parentPath)
                completionHandler(resultItem, [], false, nil)
                if let manager = NSFileProviderManager(for: self.domain) {
                    manager.signalEnumerator(for: item.parentItemIdentifier) { _ in }
                    if renamed && oldParentIdentifier != item.parentItemIdentifier {
                        manager.signalEnumerator(for: oldParentIdentifier) { _ in }
                    }
                }
            } catch {
                self.mlog.error("modifyItem(\(oldPath) → \(newPath)) failed: \("\(error)")")
                if !(error is FileProviderDirectClientError) {
                    emitMountError(mlog: self.mlog, op: renamed ? "rename" : "writefile",
                                   path: oldPath, error: error)
                }
                completionHandler(nil, [], false, Self.mapError(error))
            }
        }
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        guard let direct = directClient else {
            completionHandler(NSFileProviderError(.noSuchItem))
            return Progress()
        }

        let path = extractPath(from: identifier)
        self.mlog.info("deleteItem(\(path))")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try direct.removeItem(path: path)
                completionHandler(nil)
                let parentPathRaw = (path as NSString).deletingLastPathComponent
                let parentIdentifier: NSFileProviderItemIdentifier =
                    (parentPathRaw.isEmpty || parentPathRaw == "/")
                        ? .rootContainer
                        : NSFileProviderItemIdentifier("item-" + parentPathRaw)
                if let manager = NSFileProviderManager(for: self.domain) {
                    manager.signalEnumerator(for: parentIdentifier) { _ in }
                }
            } catch {
                self.mlog.error("deleteItem(\(path)) failed: \("\(error)")")
                if !(error is FileProviderDirectClientError) {
                    emitMountError(mlog: self.mlog, op: "remove",
                                   path: path, error: error)
                }
                completionHandler(Self.mapError(error))
            }
        }
        return Progress()
    }


    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        self.mlog.info("Creating enumerator for: \(containerItemIdentifier.rawValue)")
        return FileProviderEnumerator(
            enumeratedItemIdentifier: containerItemIdentifier,
            mountID: mountID,
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
            // Parse-free heuristic: server error text varies by protocol (SMB,
            // WebDAV, SFTP) so we match keywords rather than error codes.
            // Intentionally loose — false positives map to noSuchItem, which is
            // a recoverable Finder state, rather than the more alarming serverUnreachable.
            let lower = message.lowercased()
            let looksLikeNotFound = lower.contains("no such")
                || lower.contains("not found")
                || lower.contains("does not exist")
            return NSFileProviderError(looksLikeNotFound ? .noSuchItem : .serverUnreachable)
        case .readFailed:
            return NSFileProviderError(.noSuchItem)
        case .thumbnailFailed:
            // Thumbnails are best-effort; the FP layer treats a `nil`
            // data payload as "fall back to generic icon" so we
            // shouldn't surface this as a real error to Finder. The
            // thumbnail call site already maps the throw to a `nil`
            // payload before this `mapDriverError` runs — but if a
            // future caller forgets that, treat it as noSuchItem so
            // Finder doesn't show a scary state.
            return NSFileProviderError(.noSuchItem)
        case .decodeFailed, .invalidConfig, .tempFileFailed:
            return NSFileProviderError(.serverUnreachable)
        }
    }
}
