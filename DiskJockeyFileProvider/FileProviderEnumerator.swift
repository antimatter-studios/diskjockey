import FileProvider
import DiskJockeyLibrary

/// Directory enumerator for a single container identifier.
///
/// Same routing model as FileProviderExtension: if a direct client is
/// available we use libftp.listdir; otherwise fall back to the XPC
/// client that talks to the Go backend. We take the directClient as an
/// optional so the extension doesn't have to build two different
/// enumerator classes.
class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let enumeratedItemIdentifier: NSFileProviderItemIdentifier
    private let mountID: String
    private let xpcClient: FileProviderXPCClient
    private let directClient: FileProviderDirectClient?
    private let mlog: TaggedLogger
    private let anchor = NSFileProviderSyncAnchor("an anchor".data(using: .utf8)!)

    init(enumeratedItemIdentifier: NSFileProviderItemIdentifier,
         mountID: String,
         xpcClient: FileProviderXPCClient,
         directClient: FileProviderDirectClient? = nil,
         mlog: TaggedLogger) {
        self.enumeratedItemIdentifier = enumeratedItemIdentifier
        self.mountID = mountID
        self.xpcClient = xpcClient
        self.directClient = directClient
        self.mlog = mlog
        super.init()
        let route = directClient != nil ? "direct" : "xpc"
        self.mlog.info("Enumerator init for \(enumeratedItemIdentifier.rawValue) (route \(route))")
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

        self.mlog.info("Listing path: \(path) (mount \(mountID))")

        if let direct = directClient {
            enumerateViaDirect(direct: direct, path: path, observer: observer)
            return
        }

        // XPC fallback
        xpcClient.listDirectory(mountID: mountID, path: path) { response in
            guard let response = response else {
                self.mlog.info("No response from XPC bridge")
                observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
                return
            }

            if case .error(let err) = response.responseType {
                self.mlog.error("Error: \(err.message)")
                observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
                return
            }

            guard case .list(let listResp) = response.responseType else {
                self.mlog.info("Unexpected response type")
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

            self.mlog.info("Enumerated \(items.count) items")
            observer.didEnumerate(items)
            observer.finishEnumerating(upTo: nil)
        }
    }

    /// Direct-path implementation. libftp.listdir is blocking, so hop
    /// off the calling queue. The observer callbacks tolerate any queue.
    private func enumerateViaDirect(direct: FileProviderDirectClient,
                                    path: String,
                                    observer: NSFileProviderEnumerationObserver) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let entries = try direct.listDir(path: path)
                let items = entries.map { info in
                    FileProviderItem(info: info.toFileItem(), parentPath: path)
                }
                self.mlog.info("direct enumerated \(items.count) items at \(path)")
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                self.mlog.error("direct listDir(\(path)) failed: \("\(error)")")
                observer.finishEnumeratingWithError(FileProviderExtension.mapError(error))
            }
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
