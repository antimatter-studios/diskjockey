//
//  FileProviderEnumerator.swift
//  DiskJockeyFileProvider
//
//  Created by Chris Thomas on 02.06.25.
//

import FileProvider

import FileProvider
import DiskJockeyHelper

class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let enumeratedItemIdentifier: NSFileProviderItemIdentifier
    private let anchor = NSFileProviderSyncAnchor("an anchor".data(using: .utf8)!)
    private let mountName = "mount1" // Hardcoded for now
    
    init(enumeratedItemIdentifier: NSFileProviderItemIdentifier) {
        self.enumeratedItemIdentifier = enumeratedItemIdentifier
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        // Only support one page (no paging)
        let path: String
        if enumeratedItemIdentifier == .rootContainer {
            path = "/"
        } else {
            // Remove "item-" prefix if present
            let raw = enumeratedItemIdentifier.rawValue
            if raw.hasPrefix("item-") {
                path = String(raw.dropFirst("item-".count))
            } else {
                path = raw
            }
        }
        // Use DiskJockeyHelper connection pool and file provider
        let pool = DiskJockeyIPCConnectionPool(socketPath: "/tmp/diskjockey.sock", maxConnections: 4)
        let provider = DiskJockeyFileProvider(mountName: mountName, pool: pool)
        guard let files = provider.listDirectory(path: path) else {
            observer.finishEnumerating(upTo: nil)
            return
        }
        let items = files.map { FileProviderItem(info: $0, parentPath: path) }
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(anchor)
    }
}

