/*
 * NTFSBackend.swift — the calls NTFSVolume makes into the NTFS driver.
 *
 * NTFSVolume.swift used to make its fs_ntfs_* and fs_core_* calls inline,
 * which tied every line of it to the Rust static library and its bridging
 * header: it could only be compiled inside the appex, and so it could only
 * be "tested" through a hand-written mirror that never loaded it
 * (diskjockey#196). NTFSDriver.swift now makes every one of those calls
 * behind this protocol, and the volume builds as DiskJockeyNTFSCore in
 * `swift test`, where a stand-in conforms instead.
 *
 * The shape follows fs_ntfs.h rather than tidying it: sentinel returns,
 * with the reason in `lastErrno()`. NTFS is read-write, so this is its own
 * protocol rather than DiskJockeyLibrary's ReadOnlyVolumeDriver, but the
 * directory walk reuses that file's verdict type.
 *
 * MIT License — see LICENSE
 */

import FSKit
import Foundation
import DiskJockeyLibrary

/// `fs_ntfs_file_type_t`, as a Swift value.
enum NTFSFileType: Equatable, Sendable {
    case unknown
    case file
    case directory
    case symlink
    /// A mount point / junction: a directory to NTFS.
    case junction

    /// The C ABI's raw value: 1 file, 2 directory, 7 symlink, 8 junction.
    init(raw: UInt32) {
        switch raw {
        case 1: self = .file
        case 2: self = .directory
        case 7: self = .symlink
        case 8: self = .junction
        default: self = .unknown
        }
    }
}

/// `fs_ntfs_attr_t`, as a Swift value. Times are seconds since the UNIX
/// epoch (signed) plus nanoseconds, as the driver reports them.
struct NTFSFileAttributes: Equatable, Sendable {
    var recordNumber: UInt64
    var size: UInt64
    var accessTime: (sec: Int64, nsec: UInt32) = (0, 0)
    var modifyTime: (sec: Int64, nsec: UInt32) = (0, 0)
    var changeTime: (sec: Int64, nsec: UInt32) = (0, 0)
    var creationTime: (sec: Int64, nsec: UInt32) = (0, 0)
    /// Synthesised POSIX mode bits.
    var mode: UInt16
    var linkCount: UInt16
    var fileType: NTFSFileType
    /// NTFS FILE_ATTRIBUTE_* bits (hidden, system, ...).
    var fileAttributes: UInt32 = 0

    static func == (a: Self, b: Self) -> Bool {
        a.recordNumber == b.recordNumber && a.size == b.size
            && a.accessTime == b.accessTime && a.modifyTime == b.modifyTime
            && a.changeTime == b.changeTime && a.creationTime == b.creationTime
            && a.mode == b.mode && a.linkCount == b.linkCount
            && a.fileType == b.fileType && a.fileAttributes == b.fileAttributes
    }
}

/// One `fs_ntfs_dirent_t`. The name is the dirent's bytes, never decoded
/// here (diskjockey#219).
struct NTFSDirectoryEntry: Equatable, Sendable {
    var name: [UInt8]
    var recordNumber: UInt64
    /// The type duplicated in the directory index, which fs_ntfs.h warns
    /// can be stale.
    var fileType: NTFSFileType
}

/// The part of `fs_ntfs_volume_info_t` the volume reports to statfs.
struct NTFSVolumeInfo: Equatable, Sendable {
    var clusterSize: UInt32
    var totalClusters: UInt64
}

/// The four NTFS timestamps `fs_ntfs_set_times_h` takes, as FILETIME
/// (100 ns ticks since 1601-01-01 UTC). Nil leaves that time alone.
struct NTFSFileTimes: Equatable, Sendable {
    var creation: Int64?
    var modification: Int64?
    var change: Int64?
    var access: Int64?
}

protocol NTFSBackend: AnyObject {

    // MARK: reading

    /// Cluster size and count, or nil when the driver cannot report them.
    func volumeInfo() -> NTFSVolumeInfo?

    /// Attributes of `path`. Nil on failure, with `lastErrno()` set.
    func stat(_ path: VolumePath) -> NTFSFileAttributes?

    /// Offers each entry of the directory at `path` to `visit`, in the
    /// driver's order — "." and ".." first, which the driver synthesises —
    /// until `visit` returns false or the entries run out.
    func walkDirectory(_ path: VolumePath,
                       _ visit: (NTFSDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk

    /// Reads up to `buffer.count` bytes of `path` from `offset`: the count
    /// read, 0 at end of file, negative on failure with `lastErrno()` set.
    func read(_ path: VolumePath, at offset: UInt64,
              into buffer: UnsafeMutableRawBufferPointer) -> Int64

    /// `fs_ntfs_readlink` with the handle and the path bound; see
    /// `SymlinkTarget` for the return-value contract.
    func readlink(_ path: VolumePath, _ buffer: UnsafeMutablePointer<CChar>,
                  _ size: Int) -> Int32

    // MARK: writing (each negative on failure, with `lastErrno()` set)

    /// Replaces the WHOLE contents of `path` with `bytes`.
    func writeContents(_ path: VolumePath, _ bytes: UnsafeRawBufferPointer) -> Int64

    /// Sets the size of `path`.
    func truncate(_ path: VolumePath, to size: UInt64) -> Int64

    /// Creates an empty file named `name` in `parent`: its MFT record
    /// number.
    func createFile(in parent: VolumePath, named name: String) -> Int64

    /// Creates a directory named `name` in `parent`: its MFT record number.
    func mkdir(in parent: VolumePath, named name: String) -> Int64

    func unlink(_ path: VolumePath) -> Int32
    func rmdir(_ path: VolumePath) -> Int32

    /// Renames `path` to `name` in the same directory, atomically
    /// replacing an existing destination (FS_NTFS_RENAME_REPLACE).
    func rename(_ path: VolumePath, toBasename name: String) -> Int32

    func setTimes(_ path: VolumePath, _ times: NTFSFileTimes) -> Int32

    /// The errno of this thread's most recent failed call, 0 when none.
    func lastErrno() -> Int32

    // MARK: the mount's lifecycle

    /// False once the handle is gone — unmounted, or lost when a remount
    /// failed — which the volume reports as EBADF.
    var isMounted: Bool { get }

    /// True when the mount sits on an fs_core device chain — a disk-image
    /// container, a partition slice or both — rather than on the plain
    /// callback device.
    var remountsThroughDeviceChain: Bool { get }

    /// Unmounts, checks the dirty bit, runs fsck when it is set, and
    /// remounts (read-write preferred, read-only fallback) on every path.
    /// `onProgress` fires on the driver's thread.
    func fsck(onProgress: @escaping (_ phase: String, _ done: UInt64, _ total: UInt64) -> Void)
        -> Result<NTFSVolume.FsckReport, Error>

    /// The device-chain counterpart of `fsck` for the deferred read-write
    /// remount: dirty check, fsck when dirty, read-write remount, falling
    /// back to read-only. Emits its own lifecycle events.
    func remountReadWriteThroughDeviceChain()

    /// Releases the mount handle. Safe to call more than once.
    func unmount()

    /// Releases the block-device context the callbacks read through.
    /// Called once, after `unmount()`.
    func releaseDevice()
}

extension NTFSBackend {
    /// `lastErrno()` as the error FSKit is handed, EIO when the driver set
    /// none: a failure with no reason is still a failure.
    func lastError(fallback: Int32 = EIO) -> Error {
        let err = lastErrno()
        return fs_errorForPOSIXError(err != 0 ? err : fallback)
    }
}
