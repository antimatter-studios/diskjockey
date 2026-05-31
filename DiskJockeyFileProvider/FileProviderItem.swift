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
        self.identifierValue = "item-" + joinPath(parentPath, info.name)
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
        // Folders enumerate + accept new children; files read/write bytes.
        // Both can be renamed, reparented, deleted. No trash — we delete
        // outright via networkfs_remove.
        if info.isDirectory {
            return [
                .allowsReading,
                .allowsContentEnumerating,
                .allowsAddingSubItems,
                .allowsRenaming,
                .allowsReparenting,
                .allowsDeleting,
            ]
        }
        return [
            .allowsReading,
            .allowsWriting,
            .allowsRenaming,
            .allowsReparenting,
            .allowsDeleting,
        ]
    }

    // MARK: - NSFileProviderItem Properties
    var filename: String {
        // Root container: return "/" rather than empty. Finder expects
        // a non-empty filename even for the root item — an empty
        // string causes `enumerator(for:)` to never be called after
        // `item(for: rootContainer)`. "/" is a conventional root
        // marker and matches what most FileProvider extensions use.
        if info.name.isEmpty { return "/" }
        return info.name
    }
    var contentType: UTType {
        // Folders short-circuit. For files, derive from the filename
        // extension so Finder + QuickLook + the thumbnailing
        // subsystem know what they're dealing with — without this,
        // every non-folder is reported as `.data` (generic binary)
        // and macOS skips `fetchThumbnailsForItemIdentifiers` because
        // it doesn't believe the item could have a preview. A `.jpg`
        // resolves to `UTType.jpeg`, `.heic` to `UTType.heic`, etc.;
        // unknowns fall back to `.data` so we don't lie about the
        // file's nature.
        if info.isDirectory { return .folder }
        let ext = (info.name as NSString).pathExtension
        if ext.isEmpty { return .data }
        return UTType(filenameExtension: ext) ?? .data
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
        // Bump `schemaVersion` whenever this struct's reported
        // properties change (capabilities, contentType, etc.) so
        // fileproviderd's cache treats every item's metadata as
        // changed and re-asks instead of serving stale records.
        // Without this, switching the contentType derivation from
        // `.data` to UTType-from-extension (which is what makes
        // Finder request thumbnails) was invisible to fileproviderd
        // because `\(name)-\(size)` is identical across builds —
        // the cache happily kept the old `kUTTypeData` UTI and
        // Finder kept skipping `fetchThumbnailsForItemIdentifiers`.
        // v3: capabilities expanded from read-only to full read/write.
        let schemaVersion = 3
        let versionString = "v\(schemaVersion)-\(info.name)-\(info.size)"
        return NSFileProviderItemVersion(
            contentVersion: versionString.data(using: .utf8)!,
            metadataVersion: versionString.data(using: .utf8)!
        )
    }
}

/// Compose a child path under a parent dir, normalising slashes so
/// "/" + "foo" produces "/foo" and "/dir" + "foo" produces "/dir/foo".
func joinPath(_ parent: String, _ name: String) -> String {
    let p = parent.isEmpty ? "/" : parent
    if p == "/" { return "/" + name }
    if p.hasSuffix("/") { return p + name }
    return p + "/" + name
}

