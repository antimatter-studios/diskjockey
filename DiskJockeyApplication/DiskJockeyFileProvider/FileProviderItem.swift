//
//  FileProviderItem.swift
//  DiskJockeyFileProvider
//
//  Created by Chris Thomas on 02.06.25.
//

import FileProvider
import UniformTypeIdentifiers

import FileProvider
import UniformTypeIdentifiers
import DiskJockeyHelper

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

    // For legacy/manual init
    init(identifier: NSFileProviderItemIdentifier) {
        self.info = DiskJockeyFileItem(name: "", size: 0, isDirectory: false)
        self.parentPath = "/"
        self.identifierValue = identifier.rawValue
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        // Root container is special
        if info.name.isEmpty && identifierValue == NSFileProviderItemIdentifier.rootContainer.rawValue {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(identifierValue)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        if parentPath == "/" {
            return .rootContainer
        }
        // parent of /foo/bar is /foo
        let comps = parentPath.split(separator: "/").filter { !$0.isEmpty }
        if comps.isEmpty { return .rootContainer }
        let parent = comps.dropLast().joined(separator: "/")
        return NSFileProviderItemIdentifier("item-/" + parent)
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
        // Only files have a size
        return info.isDirectory ? nil : NSNumber(value: info.size)
    }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: "1".data(using: .utf8)!, metadataVersion: "1".data(using: .utf8)!)
    }
}

