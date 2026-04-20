/*
 * FileSystemBackend.swift — Protocol abstracting filesystem data sources.
 *
 * Any data source (local ext4, remote Dropbox, S3, etc.) can back an
 * FSKit volume by conforming to this protocol.
 *
 * MIT License — see LICENSE
 */

import Foundation

// MARK: - Value types

enum BackendFileType {
    case unknown
    case file
    case directory
    case charDevice
    case blockDevice
    case fifo
    case socket
    case symlink
}

struct BackendFileAttributes {
    var fileID: UInt64
    var fileType: BackendFileType
    var mode: UInt16
    var uid: UInt32
    var gid: UInt32
    var size: UInt64
    var linkCount: UInt16
    var atime: UInt32
    var mtime: UInt32
    var ctime: UInt32
    var crtime: UInt32
}

struct BackendDirectoryEntry {
    var fileID: UInt64
    var fileType: BackendFileType
    var name: String
}

struct BackendVolumeInfo {
    var name: String
    var blockSize: UInt32
    var totalBlocks: UInt64
    var freeBlocks: UInt64
    var totalInodes: UInt32
    var freeInodes: UInt32
    /// `true` if the filesystem was not cleanly unmounted last time it
    /// was used — the host app surfaces this as a dirty badge and can
    /// trigger fsck. Sourced from the driver's on-disk metadata (e.g.
    /// ext4 `s_state`); no Swift-side on-disk parsing.
    var mountedDirty: Bool
}

// MARK: - Protocol

protocol FileSystemBackend: AnyObject {
    /// Get volume-level statistics.
    func volumeInfo() -> BackendVolumeInfo

    /// Tear down the backend (unmount, close connections, etc.).
    func shutdown()

    /// Get file/directory attributes for a path.
    func stat(path: String) -> BackendFileAttributes?

    /// List all entries in a directory.
    func readDirectory(path: String) -> [BackendDirectoryEntry]?

    /// Read file data into a buffer. Returns bytes read, or -1 on error.
    func readFile(path: String, offset: UInt64, length: UInt64,
                  buffer: UnsafeMutableRawPointer) -> Int64

    /// Read a symbolic link target. Returns nil on error.
    func readSymlink(path: String) -> String?
}
