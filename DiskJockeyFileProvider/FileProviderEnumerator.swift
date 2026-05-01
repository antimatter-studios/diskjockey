import FileProvider
import DiskJockeyLibrary

/// Directory enumerator for a single container identifier. Every mount
/// is direct (libnetworkfs linked in-process); if the direct client is
/// absent it means config/keychain was missing, so we surface
/// `.noSuchItem` and let Finder prune.
class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let enumeratedItemIdentifier: NSFileProviderItemIdentifier
    private let mountID: String
    private let directClient: FileProviderDirectClient?
    private let mlog: TaggedLogger
    private let anchor = NSFileProviderSyncAnchor("an anchor".data(using: .utf8)!)

    init(enumeratedItemIdentifier: NSFileProviderItemIdentifier,
         mountID: String,
         directClient: FileProviderDirectClient?,
         mlog: TaggedLogger) {
        self.enumeratedItemIdentifier = enumeratedItemIdentifier
        self.mountID = mountID
        self.directClient = directClient
        self.mlog = mlog
        super.init()
        self.mlog.info("Enumerator init for \(enumeratedItemIdentifier.rawValue) (direct=\(directClient != nil))")
    }

    func invalidate() { }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        // Determine the filesystem path from the container identifier.
        let path: String
        if enumeratedItemIdentifier == .rootContainer {
            path = "/"
        } else {
            let raw = enumeratedItemIdentifier.rawValue
            path = raw.hasPrefix("item-") ? String(raw.dropFirst("item-".count)) : "/"
        }

        self.mlog.info("Listing path: \(path) (mount \(mountID))")

        guard let direct = directClient else {
            observer.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
            return
        }

        // libnetworkfs listdir is blocking — hop off the calling queue.
        // The observer callbacks tolerate any queue.
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
                // DirectClient emits `mount.error` for its own throws;
                // surface anything else (defensive — listDir today only
                // throws FileProviderDirectClientError, but if a future
                // refactor adds untyped throws into this block we still
                // want them on the host's banner).
                if !(error is FileProviderDirectClientError) {
                    emitMountError(mlog: self.mlog, op: "listDir",
                                   path: path, error: error)
                }
                observer.finishEnumeratingWithError(FileProviderExtension.mapError(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        // Static enumeration only — no change tracking yet.
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        // Use current timestamp so the anchor always changes, forcing re-enumeration.
        let now = "\(Date().timeIntervalSince1970)".data(using: .utf8)!
        completionHandler(NSFileProviderSyncAnchor(now))
    }
}
