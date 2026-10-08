import Foundation
import DiskJockeyLibrary

/// Hardware capability is not permission to write. FSKit's --rdonly and
/// POSIX ro always veto rw, including contradictory or repeated options.
enum XfsMountPolicy: Equatable {
    case readOnly
    case readWrite

    init(options: [String]) {
        let flags = Set(options.flatMap { $0.split(separator: ",").map(String.init) })
        self = flags.contains("rw") && !flags.contains("ro") && !flags.contains("--rdonly")
            ? .readWrite : .readOnly
    }

    func checkHardware(isWritable: Bool) throws {
        if self == .readWrite && !isWritable { throw POSIXError(.EROFS) }
    }

    /// Consume the mounted driver's result, not superblock feature guesses.
    /// A refused mount is never retried with weaker options here.
    func authorize(deviceIsWritable: Bool,
                   mountedDriver: Result<Bool, POSIXError>) throws -> XfsMountAccess {
        try checkHardware(isWritable: deviceIsWritable)
        let driverIsWritable = try mountedDriver.get()
        guard self == .readWrite else { return .readOnly }
        guard driverIsWritable else { throw POSIXError(.EROFS) }
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
