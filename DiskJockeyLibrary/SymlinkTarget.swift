//
//  SymlinkTarget.swift — reading a symbolic link through a driver's
//  fs_<fs>_readlink, in the one place a test can reach it.
//
//  THE CONTRACT
//
//  Every driver in the family shares one readlink contract:
//
//      int fs_<fs>_readlink(fs, path, buf, bufsize);
//
//    >= 0  success: the target's length in bytes, NOT counting the NUL,
//          as readlink(2) returns it. `buf` holds the target and a NUL.
//    -1    failure, with fs_<fs>_last_errno() set:
//          ERANGE  bufsize < length + 1. Nothing is written; the target
//                  is never silently truncated.
//          EINVAL  a NULL argument, or `path` is not a symbolic link.
//          other   ENOENT, EIO, ...
//
//  WHY THIS EXISTS
//
//  The volumes tested `rc == 0` for success. NTFS, XFS and Btrfs already
//  returned the length, so every symlink read on those volumes failed
//  with EIO; EROFS and SquashFS returned 0 until they moved onto the
//  shared contract, at which point they would have failed the same way.
//  Five hand-written copies of the check drifted from the drivers
//  together, and none of them was reachable from a test. The decision
//  lives here now; each volume passes in its C call and its errno.
//

import Foundation

/// What one `fs_<fs>_readlink` call reported.
public enum ReadlinkOutcome: Equatable, Sendable {
    /// The link's target.
    case target(String)
    /// The buffer was too small (ERANGE); nothing was written.
    case bufferTooSmall
    /// Any other failure, with the errno to report.
    case failed(errno: Int32)
}

public enum SymlinkTarget {

    /// Room for any target XFS, EROFS or SquashFS can hold, and for most
    /// NTFS reparse points, so the retry below is rarely taken.
    public static let initialCapacity = 4096

    /// Past this, a target is refused rather than chased. An NTFS reparse
    /// buffer is at most 16 KiB, so no real target reaches it.
    public static let maximumCapacity = 1 << 20

    /// Interprets one readlink call: its return value `rc`, the buffer it
    /// wrote into, and the driver's errno for the call.
    public static func outcome(rc: Int32, buffer: [CChar], errno: Int32) -> ReadlinkOutcome {
        guard rc >= 0 else {
            if errno == ERANGE { return .bufferTooSmall }
            return .failed(errno: errno != 0 ? errno : EIO)
        }
        // The length is the answer; the NUL is a courtesy. A length the
        // buffer could not have held (room for the NUL included) is a
        // driver fault, and reading past it would invent a target.
        let length = Int(rc)
        guard length < buffer.count else { return .failed(errno: EIO) }
        let bytes = buffer.prefix(length).map { UInt8(bitPattern: $0) }
        return .target(String(decoding: bytes, as: UTF8.self))
    }

    /// Reads a link's target through one driver's readlink, growing the
    /// buffer on ERANGE until the target fits or `maximumCapacity` is
    /// passed (ENAMETOOLONG). Any other failure is thrown through
    /// `makeError` with the driver's errno, EIO when it set none.
    ///
    /// `call` is the C function with its `fs` and `path` bound;
    /// `lastErrno` is that driver's fs_<fs>_last_errno.
    public static func read(
        initialCapacity: Int = initialCapacity,
        maximumCapacity: Int = maximumCapacity,
        lastErrno: () -> Int32,
        error makeError: (Int32) -> Error = { POSIXError(POSIXErrorCode(rawValue: $0) ?? .EIO) },
        _ call: (UnsafeMutablePointer<CChar>, Int) -> Int32
    ) throws -> String {
        var capacity = max(initialCapacity, 1)
        while capacity <= maximumCapacity {
            var buf = [CChar](repeating: 0, count: capacity)
            let rc = buf.withUnsafeMutableBufferPointer { call($0.baseAddress!, $0.count) }
            switch outcome(rc: rc, buffer: buf, errno: rc < 0 ? lastErrno() : 0) {
            case .target(let target):
                return target
            case .bufferTooSmall:
                capacity *= 2
            case .failed(let errno):
                throw makeError(errno)
            }
        }
        throw makeError(ENAMETOOLONG)
    }
}
