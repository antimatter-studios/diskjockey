/*
 * BcachefsBackend.swift — the calls BcachefsVolume makes into the bcachefs
 * driver, as a protocol a test can stand in for.
 *
 * BcachefsDriver.swift makes every fs_bcachefs_* and fs_core_* call behind
 * this protocol, so BcachefsVolume.swift builds without the bridging header
 * and the volume's decisions — what each FSKit operation does with the
 * driver's answer — are reached by DiskJockeyBCACHEFSCoreTests (on the model
 * of NTFSBackend, diskjockey#196).
 *
 * The shape follows fs_bcachefs.h rather than tidying it. Reads answer nil,
 * false or a negative count on failure, with the reason in `lastErrno()`;
 * writes answer 0 or the driver's negative errno, which `lastErrno()`
 * repeats. Every errno is the platform's number (rust-fs-bcachefs 0.4.1,
 * fs_bcachefs_last_errno).
 *
 * MIT License — see LICENSE
 */

import FSKit
import Foundation
import DiskJockeyLibrary

/// A file's type, from its `st_mode` or a dirent's DT_* number.
enum BcachefsFileType: Equatable, Sendable {
    case file
    case directory
    case symlink
    case charDevice
    case blockDevice
    case fifo
    case socket
    /// A dirent naming a subvolume (bcachefs's own d_type, 16). The C ABI
    /// reads the root subvolume only, so it is listed and not entered.
    case subvolume
    case unknown

    /// From `st_mode`'s S_IFMT bits.
    init(mode: UInt32) {
        switch mode & 0o170000 {
        case 0o100000: self = .file
        case 0o040000: self = .directory
        case 0o120000: self = .symlink
        case 0o020000: self = .charDevice
        case 0o060000: self = .blockDevice
        case 0o010000: self = .fifo
        case 0o140000: self = .socket
        default: self = .unknown
        }
    }

    /// From a dirent's d_type, in the DT_* numbering fs_bcachefs.h names.
    init(dType: UInt8) {
        switch dType {
        case 8: self = .file          // DT_REG
        case 4: self = .directory     // DT_DIR
        case 10: self = .symlink      // DT_LNK
        case 2: self = .charDevice    // DT_CHR
        case 6: self = .blockDevice   // DT_BLK
        case 1: self = .fifo          // DT_FIFO
        case 12: self = .socket       // DT_SOCK
        case 16: self = .subvolume    // bcachefs's subvolume dirent
        default: self = .unknown
        }
    }

    var fsItemType: FSItem.ItemType {
        switch self {
        case .file: return .file
        case .directory, .subvolume: return .directory
        case .symlink: return .symlink
        case .charDevice: return .charDevice
        case .blockDevice: return .blockDevice
        case .fifo: return .fifo
        case .socket: return .socket
        case .unknown: return .unknown
        }
    }
}

/// A time as the driver reports it: seconds and nanoseconds since the epoch.
struct BcachefsTime: Equatable, Sendable {
    var seconds: Int64
    var nanoseconds: UInt32

    static let epoch = BcachefsTime(seconds: 0, nanoseconds: 0)

    var timespec: Darwin.timespec {
        Darwin.timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds))
    }
}

/// `fs_bcachefs_attr_t` and `fs_bcachefs_times_t`, as one Swift value.
struct BcachefsFileAttributes: Equatable, Sendable {
    var inode: UInt64
    /// `st_mode`: the type bits and the permission bits.
    var mode: UInt32
    var linkCount: UInt32
    var uid: UInt32
    var gid: UInt32
    var size: UInt64
    /// 512-byte sectors allocated.
    var sectors: UInt64
    var accessTime: BcachefsTime = .epoch
    var modifyTime: BcachefsTime = .epoch
    var changeTime: BcachefsTime = .epoch

    var fileType: BcachefsFileType { BcachefsFileType(mode: mode) }
}

/// One `fs_bcachefs_dirent_t`. The name is the dirent's bytes, never
/// decoded here (diskjockey#219).
struct BcachefsDirectoryEntry: Equatable, Sendable {
    var name: [UInt8]
    var inode: UInt64
    var fileType: BcachefsFileType
}

/// What the volume reports to statfs: `fs_bcachefs_statfs_t`.
struct BcachefsVolumeInfo: Equatable, Sendable {
    var blockSize: UInt32
    var bucketSize: UInt32
    var totalBytes: UInt64
    var freeBytes: UInt64
}

protocol BcachefsBackend: AnyObject {

    // MARK: reading

    /// Capacity and free space, or nil when the driver cannot report them.
    func volumeInfo() -> BcachefsVolumeInfo?

    /// Attributes of `path`, not following a final symlink. Nil on failure.
    func stat(_ path: VolumePath) -> BcachefsFileAttributes?

    /// Offers each entry of the directory at `path` to `visit`, in the
    /// driver's order, until `visit` returns false or the entries run out.
    func walkDirectory(_ path: VolumePath,
                       _ visit: (BcachefsDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk

    /// Up to `buffer.count` bytes of `path` from `offset`: the count read,
    /// 0 at end of file, negative on failure.
    func read(_ path: VolumePath, at offset: UInt64,
              into buffer: UnsafeMutableRawBufferPointer) -> Int64

    /// A symlink's target. Nil on failure (EINVAL: not a symlink).
    func readlink(_ path: VolumePath) -> [UInt8]?

    /// The names of `path`'s extended attributes, each with its namespace
    /// ("user.colour"). Nil on failure.
    func listXattrs(_ path: VolumePath) -> [[UInt8]]?

    /// The value of the extended attribute `name` (with its namespace).
    /// Nil on failure (ENOATTR: no such attribute).
    func getXattr(_ path: VolumePath, name: [UInt8]) -> [UInt8]?

    // MARK: writing (0, or the driver's negative errno)

    /// Whether this mount has a write handle. False for a read-only mount.
    var isWritable: Bool { get }

    func create(_ path: VolumePath, mode: UInt32) -> Int32
    func mkdir(_ path: VolumePath, mode: UInt32) -> Int32
    func unlink(_ path: VolumePath) -> Int32
    func rmdir(_ path: VolumePath) -> Int32
    /// A file already at `to` is replaced; a directory may move to another.
    func rename(_ from: VolumePath, to: VolumePath) -> Int32
    func symlink(_ path: VolumePath, target: [UInt8]) -> Int32
    func link(_ existing: VolumePath, to path: VolumePath) -> Int32
    /// Replaces the WHOLE contents of `path` with `bytes`.
    func writeFile(_ path: VolumePath, _ bytes: UnsafeRawBufferPointer) -> Int32
    func chmod(_ path: VolumePath, mode: UInt32) -> Int32
    func chown(_ path: VolumePath, uid: UInt32, gid: UInt32) -> Int32
    func setXattr(_ path: VolumePath, name: [UInt8], value: [UInt8]) -> Int32
    func removeXattr(_ path: VolumePath, name: [UInt8]) -> Int32

    /// The errno of this thread's most recent failed call.
    func lastErrno() -> Int32

    /// Releases the handles. Called at most once.
    func unmount()
}

extension BcachefsBackend {
    /// `lastErrno()` as the error FSKit is handed, EIO when the driver set
    /// none: a failure with no reason is still a failure.
    func lastError() -> POSIXError {
        Self.error(lastErrno())
    }

    /// The error for a write's return value: its own negative errno.
    func error(returned rc: Int32) -> POSIXError {
        Self.error(rc < 0 ? -rc : lastErrno())
    }

    static func error(_ errno: Int32) -> POSIXError {
        guard errno > 0, let code = POSIXErrorCode(rawValue: errno) else {
            return POSIXError(.EIO)
        }
        return POSIXError(code)
    }
}
