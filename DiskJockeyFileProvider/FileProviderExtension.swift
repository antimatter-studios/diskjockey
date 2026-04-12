import FileProvider
import DiskJockeyLibrary

class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let mountID: String
    let xpcClient = FileProviderXPCClient()

    required init(domain: NSFileProviderDomain) {
        // The domain identifier encodes the backend mount ID (e.g. "3")
        self.mountID = domain.identifier.rawValue
        super.init()
        NSLog("[FileProviderExtension] Initialized for mount: %@", mountID)
    }

    func invalidate() {
        NSLog("[FileProviderExtension] Invalidating extension for mount: %@", mountID)
    }

    // MARK: - Item Resolution

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        NSLog("[FileProviderExtension] item(for: %@)", identifier.rawValue)

        // Root container is synthetic — no backend call needed
        if identifier == .rootContainer {
            let rootItem = FileProviderItem(
                info: DiskJockeyFileItem(name: "", size: 0, isDirectory: true),
                parentPath: ""
            )
            completionHandler(rootItem, nil)
            return Progress()
        }

        let path = extractPath(from: identifier)

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

    // MARK: - File Contents

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let path = extractPath(from: itemIdentifier)
        NSLog("[FileProviderExtension] fetchContents for: %@", path)

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
        completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:]))
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
            xpcClient: xpcClient
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
}
