import Foundation
import DiskJockeyLibrary

/// XFS mounts read-write by default (diskjockey#343): no option is needed
/// to ask for writes. FSKit's --rdonly and POSIX ro always veto them,
/// including contradictory or repeated options. Read-only hardware and a
/// mounted driver that cannot write give a read-only mount, never a
/// refused one, and that mount's mutations answer EROFS.
enum XfsMountPolicy: Equatable {
    case readOnly
    case readWrite

    init(options: [String]) {
        let flags = Set(options.flatMap { $0.split(separator: ",").map(String.init) })
        self = flags.contains("ro") || flags.contains("--rdonly") ? .readOnly : .readWrite
    }

    /// Whether to ask the driver for a writable mount at all: not for a
    /// read-only request, and not on hardware that cannot be written.
    func requestsWritableMount(deviceIsWritable: Bool) -> Bool {
        self == .readWrite && deviceIsWritable
    }

    /// Consume the mounted driver's result, not superblock feature guesses.
    /// A refused mount is never retried with weaker options here; a mounted
    /// driver that cannot write is a read-only mount.
    func authorize(deviceIsWritable: Bool,
                   mountedDriver: Result<Bool, POSIXError>) throws -> XfsMountAccess {
        let driverIsWritable = try mountedDriver.get()
        guard requestsWritableMount(deviceIsWritable: deviceIsWritable),
              driverIsWritable else { return .readOnly }
        return XfsMountAccess(allowsWrites: true)
    }
}

/// Only the policy's mounted-driver check can construct writable access.
struct XfsMountAccess {
    static let readOnly = XfsMountAccess(allowsWrites: false)
    let allowsWrites: Bool
    fileprivate init(allowsWrites: Bool) { self.allowsWrites = allowsWrites }
}

/// The capability belongs to this mounted handle, not the driver in general.
protocol XfsMountedVolumeDriver: ReadOnlyVolumeDriver {
    var isWritable: Bool { get }

    /// fs_xfs_write_file: overwrite bytes the file already holds. The
    /// count written, or negative with the reason in `lastErrno()`.
    func write(_ path: VolumePath, at offset: UInt64,
               from buffer: UnsafeRawBufferPointer) -> Int64

    /// fs_xfs_truncate: set the file's size, zero-filling a longer one. A
    /// nil `modified` stamps nothing. Zero, or negative with the reason in
    /// `lastErrno()`.
    func truncate(_ path: VolumePath, to size: UInt64, modified: timespec?) -> Int32

    /// fs_xfs_flush: write everything the handle has logged to its home on
    /// the device. Zero, or negative with the reason in `lastErrno()`.
    func flush() -> Int32

    /// fs_xfs_create and fs_xfs_mkdir: a new empty regular file, or
    /// directory, with permission bits `mode`, owned by uid 0 and gid 0.
    /// Its inode number, or 0 with the reason in `lastErrno()`.
    func create(_ path: VolumePath, mode: UInt16) -> UInt64
    func mkdir(_ path: VolumePath, mode: UInt16) -> UInt64

    /// fs_xfs_unlink (a file or symlink) and fs_xfs_rmdir (an empty
    /// directory). Zero, or negative with the reason in `lastErrno()`.
    func unlink(_ path: VolumePath) -> Int32
    func rmdir(_ path: VolumePath) -> Int32

    /// fs_xfs_link: a second name, `destination`, for the file at `source`.
    /// Zero, or negative with the reason in `lastErrno()`.
    func link(_ source: VolumePath, to destination: VolumePath) -> Int32

    /// fs_xfs_rename2: move `source` to `destination` in one record,
    /// replacing a name there when `replace` (FS_XFS_RENAME_REPLACE), as
    /// rename(2) does. Zero, or negative with the reason in `lastErrno()`.
    func rename(_ source: VolumePath, to destination: VolumePath, replace: Bool) -> Int32

    /// fs_xfs_set_attributes: each field nil is left as it is. Zero, or
    /// negative with the reason in `lastErrno()`.
    func setAttributes(_ path: VolumePath, mode: UInt32?, uid: UInt32?, gid: UInt32?,
                       accessed: timespec?, modified: timespec?) -> Int32

    /// fs_xfs_getxattr: an extended attribute's value by its XFS name
    /// (namespace included), or nil with the reason in `lastErrno()`.
    func getXattr(_ path: VolumePath, name: [UInt8]) -> [UInt8]?
    /// fs_xfs_listxattr: every attribute's XFS name, or nil.
    func listXattrs(_ path: VolumePath) -> [[UInt8]]?
    /// fs_xfs_setxattr with its flags (0, CREATE or REPLACE), and
    /// fs_xfs_removexattr. Zero, or negative with the reason in `lastErrno()`.
    func setXattr(_ path: VolumePath, name: [UInt8], value: [UInt8], flags: Int32) -> Int32
    func removeXattr(_ path: VolumePath, name: [UInt8]) -> Int32
}
