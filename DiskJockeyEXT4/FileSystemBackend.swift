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
    /// SECONDS ARE SIGNED AND SIXTY-FOUR BITS WIDE, matching the driver
    /// as of am-fs-ext4 0.5.0 and the on-disk field it comes from.
    ///
    /// ext4's base timestamp is a signed 32-bit value that its matching
    /// `*_extra` field extends by two more bits, so the real range is
    /// roughly 1901 to 2446. Held as `UInt32` here, everything before
    /// 1970 read back as a date in the far future and everything after
    /// 2038 was truncated -- and neither showed up as an error, only as
    /// a wrong date in the Finder.
    var atime: Int64
    var mtime: Int64
    var ctime: Int64
    var crtime: Int64
}

struct BackendDirectoryEntry {
    var fileID: UInt64
    var fileType: BackendFileType
    var name: String
}

/// Mirror of `fs_ext4_volume_info_t`. Everything the on-disk
/// superblock exposes is surfaced here so the host app can render
/// rich volume info without parsing the disk itself. Optional fields
/// are populated only when the source FFI returns them — the NTFS
/// backend's volumeInfo, for example, leaves the ext4-specific
/// timestamps and feature bitmaps as nil.
struct BackendVolumeInfo {
    /* ----- Identity ----- */
    var name: String
    var uuid: String?            /* canonical 8-4-4-4-12 hex */
    var lastMounted: String?     /* path the FS was last mounted at */

    /* ----- Sizing ----- */
    var blockSize: UInt32
    var totalBlocks: UInt64
    var freeBlocks: UInt64
    var reservedBlocks: UInt64?  /* root-reserve blocks */
    var totalInodes: UInt32
    var freeInodes: UInt32
    var inodeSize: UInt16?
    var firstInode: UInt32?
    var blocksPerGroup: UInt32?
    var inodesPerGroup: UInt32?

    /* ----- Provenance + capabilities ----- */
    var creatorOS: UInt32?
    var revLevel: UInt32?
    var minorRevLevel: UInt16?
    var featureCompat: UInt32?
    var featureIncompat: UInt32?
    var featureRoCompat: UInt32?
    var descSize: UInt16?
    var defaultHashVersion: UInt8?

    /* ----- Lifecycle / health ----- */
    var state: UInt16?
    var errorsBehavior: UInt16?
    var lastMountTime: UInt32?   /* unix epoch */
    var lastWriteTime: UInt32?
    var lastCheckTime: UInt32?
    var checkInterval: UInt32?
    var mountCount: UInt16?
    var maxMountCount: UInt16?
    var defResUID: UInt16?
    var defResGID: UInt16?

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
    /// NOTE: this REPLACES the whole file. Use `pwrite` for partial /
    /// streaming writes; `writeFile` is the "save-as" / whole-file-replace
    /// primitive.
    func writeFile(path: String, data: UnsafeRawPointer, length: UInt64) -> Int64

    /// Positional streaming write: splice `length` bytes from `data` into
    /// `path` at byte `offset`. Costs O(length), not O(filesize) — unlike
    /// `writeFile` which rewrites the entire file. Returns the new file
    /// size on success, or -1 on error. The file must already exist.
    /// Cap: 1 GiB per call (chunk if you have more).
    func pwrite(path: String, offset: UInt64,
                data: UnsafeRawPointer, length: UInt64) -> Int64

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

    /// The driver's last error message, or a stand-in when it set none.
    ///
    /// A COMPANION TO `lastErrno`, AND THE REASON IT IS ON THE PROTOCOL:
    /// the volume used to read this straight out of the C ABI with
    /// `fs_ext4_last_error()`, which was the ONLY C reference in 903 lines
    /// of otherwise pure Swift — enough on its own to make the whole file
    /// need the Rust static library to compile, and so to make it
    /// untestable without one. The conforming type already owns the C
    /// boundary; this is the one call that had leaked past it.
    func lastErrorMessage() -> String

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
