import FileProvider
import DiskJockeyLibrary

class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let enumeratedItemIdentifier: NSFileProviderItemIdentifier
    private let mountID: String
    private let xpcClient: FileProviderXPCClient
    private let anchor = NSFileProviderSyncAnchor("an anchor".data(using: .utf8)!)

    init(enumeratedItemIdentifier: NSFileProviderItemIdentifier, mountID: String, xpcClient: FileProviderXPCClient) {
        self.enumeratedItemIdentifier = enumeratedItemIdentifier
        self.mountID = mountID
        self.xpcClient = xpcClient
        super.init()
        NSLog("[FileProviderEnumerator] Init for %@ (mount %@)", enumeratedItemIdentifier.rawValue, mountID)
    }

    func invalidate() { }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        // Determine the filesystem path from the container identifier
        let path: String
        if enumeratedItemIdentifier == .rootContainer {
            path = "/"
        } else {
            let raw = enumeratedItemIdentifier.rawValue
            path = raw.hasPrefix("item-") ? String(raw.dropFirst("item-".count)) : "/"
        }

        NSLog("[FileProviderEnumerator] Listing path: %@ (mount %@)", path, mountID)

        xpcClient.listDirectory(mountID: mountID, path: path) { response in
            guard let response = response else {
                NSLog("[FileProviderEnumerator] No response from XPC bridge")
                observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
                return
            }

            if case .error(let err) = response.responseType {
                NSLog("[FileProviderEnumerator] Error: %@", err.message)
                observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
                return
            }

            guard case .list(let listResp) = response.responseType else {
                NSLog("[FileProviderEnumerator] Unexpected response type")
                observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
                return
            }

            let items = listResp.files.map { file in
                FileProviderItem(
                    info: DiskJockeyFileItem(
                        name: file.name,
                        size: file.size,
                        isDirectory: file.isDirectory
                    ),
                    parentPath: path
                )
            }

            NSLog("[FileProviderEnumerator] Enumerated %d items", items.count)
            observer.didEnumerate(items)
            observer.finishEnumerating(upTo: nil)
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        // Static enumeration only — no change tracking yet
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        // Use current timestamp so the anchor always changes, forcing re-enumeration
        let now = "\(Date().timeIntervalSince1970)".data(using: .utf8)!
        completionHandler(NSFileProviderSyncAnchor(now))
    }
}
