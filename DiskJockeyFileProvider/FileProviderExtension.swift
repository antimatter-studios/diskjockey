import FileProvider
import DiskJockeyLibrary

/// Principal class for the FileProvider extension.
///
/// Routing model: every mount is *either* direct (libftp.a linked in
/// process) or XPC-backed (forwards to the Go backend over
/// NSXPCConnection). We figure out which at init time by checking for
/// a `DirectMountConfig` plist in the shared app group. If present →
/// direct client. If missing (or any load error) → fall back to the
/// existing XPC client.
///
/// The fallback is *critical*. Old mounts predating direct-mount
/// support won't have a config plist or keychain entry; they must keep
/// working on the XPC path. Don't remove it.
class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let mountID: String

    /// Always present; used for legacy mounts + as a fallback when the
    /// direct-client init fails for any reason.
    let xpcClient = FileProviderXPCClient()

    /// Present only when a DirectMountConfig + keychain entry exist for
    /// this domain. Read-only after init — FileProvider may hand us
    /// concurrent op requests.
    let directClient: FileProviderDirectClient?

    required init(domain: NSFileProviderDomain) {
        // The domain identifier encodes either the backend mount ID
        // (legacy: "3") or a UUID (direct mounts). The value is opaque
        // to the routing layer — it's just a lookup key.
        self.mountID = domain.identifier.rawValue

        // Try to build a direct client. If the config/keychain isn't
        // there, this mount hasn't been migrated — fall back to XPC.
        let store = MountConfigStore()
        if store.exists(domainID: mountID) {
            do {
                self.directClient = try FileProviderDirectClient(domainID: mountID)
                NSLog("[FileProviderExtension] direct client ready for %@", mountID)
            } catch {
                NSLog("[FileProviderExtension] direct-client init failed for %@: %@; using XPC fallback",
                      mountID, "\(error)")
                self.directClient = nil
            }
        } else {
            self.directClient = nil
            NSLog("[FileProviderExtension] no direct config for %@; using XPC", mountID)
        }

        super.init()
        NSLog("[FileProviderExtension] Initialized for mount: %@", mountID)
        // libftp smoke-test log stays for diagnostic parity with the
        // Phase-1 wiring. Harmless when libftp isn't linked — returns
        // "(unavailable)" instead of crashing.
        NSLog("[FileProviderExtension] libftp version: %@", FTPDriver.libraryVersion())
    }

    func invalidate() {
        NSLog("[FileProviderExtension] Invalidating extension for mount: %@", mountID)
        directClient?.disconnect()
    }

    // MARK: - Item Resolution

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        NSLog("[FileProviderExtension] item(for: %@)", identifier.rawValue)

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

        // Direct path: libftp stat.
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
                NSLog("[FileProviderExtension] stat error: %@", err.message)
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

    /// Direct-path implementation of `item(for:)`. libftp stat is
    /// synchronous; we run it off the calling thread so we don't block
    /// the FileProvider-owned queue.
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
                NSLog("[FileProviderExtension] direct stat(%@) failed: %@", path, "\(error)")
                completionHandler(nil, Self.mapError(error))
            }
        }
    }

    // MARK: - File Contents

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let path = extractPath(from: itemIdentifier)
        NSLog("[FileProviderExtension] fetchContents for: %@", path)

        if let direct = directClient {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let url = try direct.fetchFile(path: path)
                    let item = FileProviderItem(identifier: itemIdentifier)
                    completionHandler(url, item, nil)
                } catch {
                    NSLog("[FileProviderExtension] direct fetch(%@) failed: %@", path, "\(error)")
                    completionHandler(nil, nil, Self.mapError(error))
                }
            }
            return Progress()
        }

        // XPC fallback
        xpcClient.readFile(mountID: mountID, path: path) { response in
            guard let response = response else {
                completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
                return
            }

            if case .error(let err) = response.responseType {
                NSLog("[FileProviderExtension] read error: %@", err.message)
                completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                return
            }

            guard case .read(let readResp) = response.responseType else {
                completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
                return
            }

            NSLog("[FileProviderExtension] fetchContents received %d bytes for %@", readResp.data.count, path)

            // Write data to a temporary file
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            do {
                try readResp.data.write(to: tempURL)
                NSLog("[FileProviderExtension] Wrote %d bytes to %@", readResp.data.count, tempURL.path)
            } catch {
                NSLog("[FileProviderExtension] Failed to write temp file: %@", error.localizedDescription)
                completionHandler(nil, nil, error)
                return
            }

            let item = FileProviderItem(identifier: itemIdentifier)
            completionHandler(tempURL, item, nil)
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
        NSLog("[FileProviderExtension] Creating enumerator for: %@", containerItemIdentifier.rawValue)
        return FileProviderEnumerator(
            enumeratedItemIdentifier: containerItemIdentifier,
            mountID: mountID,
            xpcClient: xpcClient,
            directClient: directClient
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
        case let d as FTPDriverError:
            return mapDriverError(d)
        default:
            return error
        }
    }

    private static func mapDriverError(_ d: FTPDriverError) -> Error {
        switch d {
        case .mountFailed, .unmountFailed:
            return NSFileProviderError(.serverUnreachable)
        case .operationFailed(_, _, _, let message):
            // FTP "no such file" / "permission denied" both land here.
            // Parse-free heuristic: anything containing "no such" or
            // "not found" → noSuchItem; else generic unreachable.
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
