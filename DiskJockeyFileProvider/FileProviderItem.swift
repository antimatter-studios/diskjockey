//
//  FileProviderItem.swift
//  DiskJockeyFileProvider
//
//  Created by Chris Thomas on 07.06.25.
//

import FileProvider
import UniformTypeIdentifiers
import DiskJockeyLibrary

class FileProviderItem: NSObject, NSFileProviderItem {
    private let info: DiskJockeyFileItem
    private let parentPath: String
    private let identifierValue: String

    /// Canonical initializer. Callers MUST pass real stat info — never
    /// fabricated. Filesystem drivers that guess at size/isDirectory
    /// from filename suffixes corrupt cached Finder metadata; we hard
    /// require the caller to have done a stat first.
    init(info: DiskJockeyFileItem, parentPath: String) {
        self.info = info
        self.parentPath = parentPath
        if parentPath == "/" {
            self.identifierValue = "item-/" + info.name
        } else {
            self.identifierValue = "item-" + (parentPath.hasSuffix("/") ? parentPath : parentPath + "/") + info.name
        }
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        // Root container: empty name with empty or "/" parent
        if info.name.isEmpty && (parentPath.isEmpty || parentPath == "/") {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(identifierValue)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        if parentPath == "/" || parentPath.isEmpty {
            return .rootContainer
        }
        // parentPath is the directory containing this item
        // e.g. parentPath="/subdir" means parent is "item-/subdir"
        let cleanPath = parentPath.hasPrefix("/") ? parentPath : "/" + parentPath
        return NSFileProviderItemIdentifier("item-" + cleanPath)
    }

    var capabilities: NSFileProviderItemCapabilities {
        // Read-only
        return [.allowsReading, .allowsContentEnumerating]
    }

    // MARK: - NSFileProviderItem Properties
    var filename: String {
        // Root container reports an empty name; everyone else must
        // have a real name. No placeholder strings — Finder caches
        // whatever we return here as the user-visible path component,
        // and a fake name ("mount1") poisons the metadata.
        return info.name
    }
    var contentType: UTType {
        // Use info.isDirectory for type
        return info.isDirectory ? .folder : .data
    }
    var isDirectory: Bool {
        return info.isDirectory
    }
    var fileSize: NSNumber? {
        return info.isDirectory ? nil : NSNumber(value: info.size)
    }
    var documentSize: NSNumber? {
        return info.isDirectory ? nil : NSNumber(value: info.size)
    }
    var itemVersion: NSFileProviderItemVersion {
        let versionString = "\(info.name)-\(info.size)"
        return NSFileProviderItemVersion(
            contentVersion: versionString.data(using: .utf8)!,
            metadataVersion: versionString.data(using: .utf8)!
        )
    }
}

