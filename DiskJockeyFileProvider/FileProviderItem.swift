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

    // Construct from DiskJockeyFileItem and parent path
    init(info: DiskJockeyFileItem, parentPath: String) {
        self.info = info
        self.parentPath = parentPath
        if parentPath == "/" {
            self.identifierValue = "item-/" + info.name
        } else {
            self.identifierValue = "item-" + (parentPath.hasSuffix("/") ? parentPath : parentPath + "/") + info.name
        }
    }

    // For legacy/manual init - used by fetchContents when we only have the identifier
    init(identifier: NSFileProviderItemIdentifier) {
        let rawPath = identifier.rawValue.replacingOccurrences(of: "item-", with: "")
        let name = (rawPath as NSString).lastPathComponent
        self.info = DiskJockeyFileItem(
            name: name,
            size: name.hasSuffix(".txt") ? 100 : 0,
            isDirectory: name.isEmpty || !name.contains(".")
        )
        self.parentPath = "/"
        self.identifierValue = identifier.rawValue
        NSLog("[FileProviderItem] Created item %@ as %@", name, info.isDirectory ? "directory" : "file")
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
        // Use "mount1" as a fallback if name is empty
        return info.name.isEmpty ? "mount1" : info.name
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

