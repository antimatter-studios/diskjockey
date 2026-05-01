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
        // Trash + workingSet are system containers we don't implement —
        // we return them as empty rather than letting the path
        // extraction below default to "/" and trigger a real listdir
        // against the remote (which on Dropbox would fill "trash" with
        // root items, on FTP/SFTP would attempt a connect we can't
        // satisfy, etc.). Finder is happy with an empty enumeration.
        if enumeratedItemIdentifier == .trashContainer ||
           enumeratedItemIdentifier == .workingSet {
            self.mlog.info("Empty enumeration for system container: \(enumeratedItemIdentifier.rawValue)")
            observer.didEnumerate([])
            observer.finishEnumerating(upTo: nil)
            return
        }

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

                // Pre-warm the thumbnail cache for image-typed entries
                // we just enumerated. Driven by us, not Finder: even
                // List view (which never asks for thumbnails) ends up
                // with the cache populated, so a later switch to icon
                // view / QuickLook is instant. Honours the same
                // toggle + cellular gates `fetchThumbnails` uses, so
                // a user on metered data isn't hit twice.
                self.prewarmThumbnails(entries: entries, parentPath: path,
                                       direct: direct)
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
        // Static enumeration only — no change tracking. Returning
        // `.syncAnchorExpired` here put fileproviderd into a tight
        // re-enumeration loop on the working-set container; the
        // safer pattern is "no changes since your anchor" plus
        // letting `currentSyncAnchor` rotate the anchor on each call
        // so fresh requests re-enumerate items naturally.
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    // MARK: - Pre-warm

    /// Default px size for the pre-warm. 256px covers icon view and
    /// small QuickLook hover; matches the cache bucket that Finder
    /// most often asks for in icon mode. If Finder later requests a
    /// different bucket (e.g. 64 for sidebar previews) it'll fetch
    /// that separately — we don't try to warm every bucket because
    /// the bandwidth cost would scale with the number of buckets.
    private static let prewarmSizePx: Int = 256

    /// Max in-flight thumbnail fetches during pre-warm. Keeps us
    /// from saturating the provider's API rate limit while still
    /// finishing a 200-photo folder in seconds rather than minutes.
    private static let prewarmConcurrency: Int = 4

    /// Fan out a background warming task that fetches thumbnails for
    /// every image-typed entry in the just-enumerated listing,
    /// caching them via `ThumbnailCache`. We drive this rather than
    /// waiting for Finder to ask: even List view, where Finder never
    /// requests thumbnails, ends up with the cache primed so a
    /// later switch to icon view / a QuickLook tap is instant.
    ///
    /// Errors are swallowed silently — pre-warm is best-effort and
    /// any genuine connection failure will surface through the
    /// banner the next time Finder asks for an op.
    private func prewarmThumbnails(entries: [RemoteFileInfo],
                                   parentPath: String,
                                   direct: FileProviderDirectClient) {
        guard direct.shouldPrewarmThumbnails else { return }
        let imageEntries = entries.filter {
            !$0.isDir && Self.isImageLike(name: $0.name)
        }
        guard !imageEntries.isEmpty else { return }
        let mountID = self.mountID
        let log = self.mlog
        let sizePx = Self.prewarmSizePx
        let concurrency = Self.prewarmConcurrency
        log.info("prewarm: \(imageEntries.count) thumbnails @ \(sizePx)px under \(parentPath)")

        // Detached so we don't tie the pre-warm to the enumerator's
        // lifecycle — Finder may invalidate the enumerator the
        // moment it has the items, but the warm should keep running.
        Task.detached(priority: .background) {
            await withTaskGroup(of: Void.self) { group in
                var inFlight = 0
                var iterator = imageEntries.makeIterator()
                func enqueueNext() -> Bool {
                    guard let entry = iterator.next() else { return false }
                    let p = (parentPath.hasSuffix("/") ? parentPath : parentPath + "/") + entry.name
                    let path = parentPath == "/" ? "/" + entry.name : p
                    group.addTask {
                        if ThumbnailCache.shared.get(
                            mountID: mountID, path: path, sizePx: sizePx
                        ) != nil {
                            return
                        }
                        do {
                            let data = try direct.fetchThumbnail(
                                path: path, sizePx: sizePx
                            )
                            ThumbnailCache.shared.put(
                                mountID: mountID, path: path,
                                sizePx: sizePx, data: data
                            )
                        } catch {
                            // Silent — pre-warm is best-effort.
                        }
                    }
                    return true
                }
                // Prime the pump.
                while inFlight < concurrency, enqueueNext() {
                    inFlight += 1
                }
                // Drain + refill: every completed task triggers
                // another so we keep `concurrency` in flight until
                // the iterator's empty.
                for await _ in group {
                    if !enqueueNext() {
                        // No more to add; let the rest drain.
                        break
                    }
                }
            }
            log.info("prewarm done at \(parentPath)")
        }
    }

    /// Cheap "is this filename probably an image we can thumbnail"
    /// check. We don't want to call out to UTType from here (the
    /// enumerator runs on a network-fetch path; UTType lookups touch
    /// the LaunchServices DB) — a hard-coded extension list catches
    /// the realistic cases for what users put in cloud storage.
    private static func isImageLike(name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif",
             "gif", "bmp", "webp", "raw", "cr2", "cr3", "nef", "arw",
             "dng", "orf", "rw2":
            return true
        default:
            return false
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        // Always return a fresh anchor so fileproviderd treats the
        // listing as "changed" and re-enumerates on every refresh —
        // we don't have a cheap delta-since API for any of the
        // remote backends so we'd rather refetch than serve stale.
        let now = "\(Date().timeIntervalSince1970)".data(using: .utf8)!
        completionHandler(NSFileProviderSyncAnchor(now))
    }
}
