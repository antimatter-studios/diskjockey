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
        // v4: versions carry the remote's kind, modification time and
        //     mode, and the item reports contentModificationDate.
        //
        // The version is the item's remote revision as far as the
        // backend lets us see it (diskjockey#588). go-networkfs reports
        // size, kind, a modification time in whole seconds and mode
        // bits; no backend exposes an ETag or other validator through
        // it. So a same-size edit is told apart by its modification
        // time, and two same-size edits inside one second, or a server
        // that preserves the old timestamp, still collide. Neither
        // version is ever derived from anything but the stat record.
        //
        // Fields are joined with NUL, which no filename can contain, so
        // a name holding the separator cannot forge another item's
        // version.
        let schemaVersion = 4
        let kind = info.isDirectory ? "dir" : "file"
        let modificationTime = info.modificationTime.map { String($0) } ?? "?"
        let mode = info.mode.map { String($0, radix: 8) } ?? "?"
        let content = ["v\(schemaVersion)", kind, String(info.size), modificationTime]
        let metadata = content + [info.name, mode]
        return NSFileProviderItemVersion(
            contentVersion: Data(content.joined(separator: "\u{0}").utf8),
            metadataVersion: Data(metadata.joined(separator: "\u{0}").utf8)
        )
    }
    var contentModificationDate: Date? {
        guard let seconds = info.modificationTime else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

/// The stat record to report for a file whose bytes were just fetched.
///
/// `before` and `after` are best-effort stats taken either side of the
/// download; either may be nil (an FTP server without MLST/MDTM cannot
/// stat at all). The remote revision is reported only when the bytes on
/// disk are known to belong to it: the stats agree with each other when
/// both exist, describe a file, and match the downloaded size. Otherwise
/// the item carries no modification time, so its version cannot equal a
/// revision the enumerator reported and fileproviderd will not mistake
/// these bytes for that revision (diskjockey#588). When only `after`
/// exists, a same-size edit landing during the download is not caught.
func fetchedFileInfo(name: String, downloadedSize: Int64,
                     before: DiskJockeyFileItem?,
                     after: DiskJockeyFileItem?) -> DiskJockeyFileItem {
    let unknown = DiskJockeyFileItem(name: name, size: downloadedSize, isDirectory: false)
    guard let after = after, !after.isDirectory, after.size == downloadedSize else {
        return unknown
    }
    if let before = before {
        guard before.isDirectory == after.isDirectory,
              before.size == after.size,
              before.modificationTime == after.modificationTime,
              before.mode == after.mode else {
            return unknown
        }
    }
    return DiskJockeyFileItem(name: name, size: downloadedSize, isDirectory: false,
                              modificationTime: after.modificationTime, mode: after.mode)
}

/// Compose a child path under a parent dir, normalising slashes so
/// "/" + "foo" produces "/foo" and "/dir" + "foo" produces "/dir/foo".
func joinPath(_ parent: String, _ name: String) -> String {
    let p = parent.isEmpty ? "/" : parent
    if p == "/" { return "/" + name }
    if p.hasSuffix("/") { return p + name }
    return p + "/" + name
}

