//
//  FileProviderEnumerator.swift
//  DiskJockeyFileProvider
//
//  
//

import FileProvider
import DiskJockeyHelperLibrary

// IMPORTANT: The File Provider extension is sandboxed and cannot access /tmp.
// The socket must be placed in the shared App Group Application Support directory.
// Update this constant if the socket location changes in the main app/helper.
// The File Provider extension must connect to the socket created by the helper/backend in the user's Application Support directory.
// This must match the path used by the backend. Do NOT create the socket here.
let diskJockeySocketPath: String = {
    let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return supportDir.appendingPathComponent("DiskJockey/diskjockey.sock").path
}()

class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let enumeratedItemIdentifier: NSFileProviderItemIdentifier
    private let anchor = NSFileProviderSyncAnchor("an anchor".data(using: .utf8)!)
    private let mountID: UInt32 = 1 // TODO: Replace with real mountID from config or API
    
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
        // DUMMY: No-op for now, just finish enumeration immediately
        observer.finishEnumerating(upTo: nil)
        return
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(anchor)
    }
}

