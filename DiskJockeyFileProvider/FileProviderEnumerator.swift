//
//  FileProviderEnumerator.swift
//  DiskJockeyFileProvider
//
//  
//

import FileProvider
import DiskJockeyLibrary

class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let enumeratedItemIdentifier: NSFileProviderItemIdentifier
    private let anchor = NSFileProviderSyncAnchor("an anchor".data(using: .utf8)!)
    
    init(enumeratedItemIdentifier: NSFileProviderItemIdentifier) {
        NSLog("[FileProviderEnumerator] Initializing with identifier: %@", enumeratedItemIdentifier.rawValue)
        self.enumeratedItemIdentifier = enumeratedItemIdentifier
        super.init()
        NSLog("[FileProviderEnumerator] Initialized successfully")
    }

    func invalidate() {
        NSLog("[FileProviderEnumerator] Invalidating enumerator")
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        NSLog("[FileProviderEnumerator] Starting enumeration for identifier: %@", enumeratedItemIdentifier.rawValue)
        
        // Only support root container for now
        guard enumeratedItemIdentifier == .rootContainer else {
            NSLog("[FileProviderEnumerator] Unsupported container identifier, finishing enumeration")
            observer.finishEnumerating(upTo: nil)
            return
        }
        
        // Create test items - root container should contain both files and directories
        let testFiles = [
            FileProviderItem(info: DiskJockeyFileItem(name: "test1.txt", size: 100, isDirectory: false), parentPath: "/"),
            FileProviderItem(info: DiskJockeyFileItem(name: "test2.txt", size: 200, isDirectory: false), parentPath: "/"),
            FileProviderItem(info: DiskJockeyFileItem(name: "Documents", size: 0, isDirectory: true), parentPath: "/")
        ]
        
        NSLog("[FileProviderEnumerator] Enumerating %d test files", testFiles.count)
        observer.didEnumerate(testFiles)
        observer.finishEnumerating(upTo: nil)
        NSLog("[FileProviderEnumerator] Finished enumeration successfully")
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        NSLog("[FileProviderEnumerator] Enumerating changes from anchor")
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
        NSLog("[FileProviderEnumerator] Finished enumerating changes")
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(anchor)
    }
}

