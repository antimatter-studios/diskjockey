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

    /// fs_xfs_truncate: shorten the file. A nil `modified` stamps nothing.
    /// Zero, or negative with the reason in `lastErrno()`.
    func truncate(_ path: VolumePath, to size: UInt64, modified: timespec?) -> Int32
}
