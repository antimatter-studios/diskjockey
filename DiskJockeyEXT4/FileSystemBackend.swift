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

    // MARK: - Write path

    /// Create an empty regular file at `path` with the given mode bits.
    /// Returns true on success.
    func createFile(path: String, mode: UInt16) -> Bool

    /// Replace the contents of `path` with `length` bytes from `data`.
    /// Returns the new size on success, or -1 on error.
    /// NOTE: this REPLACES the whole file. Callers needing partial writes
    /// must do read-modify-write themselves.
    func writeFile(path: String, data: UnsafeRawPointer, length: UInt64) -> Int64

    /// Remove a non-directory file. Returns true on success.
    func unlink(path: String) -> Bool

    /// Move/rename src → dst. Returns true on success.
    func rename(src: String, dst: String) -> Bool

    /// Create a directory. Returns true on success.
    func mkdir(path: String, mode: UInt16) -> Bool

    /// Remove an empty directory. Returns true on success.
    func rmdir(path: String) -> Bool

    /// Shrink a regular file to `size` bytes.
    func truncate(path: String, size: UInt64) -> Bool

    /// Change permission bits.
    func chmod(path: String, mode: UInt16) -> Bool

    /// Change owner. Pass `nil` for either component to leave it unchanged.
    func chown(path: String, uid: UInt32?, gid: UInt32?) -> Bool

    /// Create a symbolic link.
    func symlink(target: String, linkpath: String) -> Bool

    /// Create a hard link.
    func link(src: String, dst: String) -> Bool

    /// Set access and/or modify times. Pass `nil` to skip a pair.
    func utimens(path: String, atime: timespec?, mtime: timespec?) -> Bool

    /// Flush pending writes to the underlying device. Returns true on success.
    func flush() -> Bool

    /// Returns the last POSIX errno from a failed call (thread-local).
    /// Returns 0 if the last call succeeded.
    func lastErrno() -> Int32

    /// Replay the on-disk journal if the volume is dirty. Idempotent —
    /// safe to call on a clean volume. Returns true on success (or
    /// already-clean), false on failure.
    ///
    /// Used to defer ext4 journal replay until AFTER FSKit's
    /// `loadResource` returns, working around a macOS limitation where
    /// the kernel-level write FD doesn't actually become writable until
    /// loadResource returns successfully.
    func replayJournalIfDirty() -> Bool
}

extension FileSystemBackend {
    /// Default implementation for backends that don't have a journal
    /// (or never need to replay one). Treats the call as a no-op.
    func replayJournalIfDirty() -> Bool { true }
}
