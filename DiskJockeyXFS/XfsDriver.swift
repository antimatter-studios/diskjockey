/*
 * XfsDriver.swift — the fs_xfs_* C ABI behind ReadOnlyVolumeDriver.
 *
 * The only file in this extension that calls the driver on behalf of the
 * volume, so that XfsVolume.swift builds without the Rust static library
 * and `swift test` can run it (DiskJockeyXFSCore in Package.swift, which
 * excludes this file). Nothing here decides anything: each method is one
 * C call and the conversion of its C types into the shared Swift ones.
 *
 * MIT License — see LICENSE
 */

import Foundation
import DiskJockeyLibrary

final class XfsDriver: XfsMountedVolumeDriver {

    private var fs: OpaquePointer?

    init(fs: OpaquePointer) {
        self.fs = fs
    }

    var isWritable: Bool {
        guard let fs else { return false }
        return fs_xfs_is_writable(fs) > 0
    }

    func volumeInfo() -> ReadOnlyVolumeInfo? {
        guard let fs else { return nil }
        var info = fs_xfs_volume_info_t()
        guard fs_xfs_get_volume_info(fs, &info) == 0 else { return nil }
        // XFS counts blocks, so the figures pass straight through, the
        // free counts included (the superblock's, as the driver keeps them
        // current).
        return ReadOnlyVolumeInfo(
            capacity: .blocks(blockSize: UInt64(info.block_size),
                              total: UInt64(info.total_blocks),
                              free: UInt64(info.free_blocks)),
            ioSize: UInt64(info.block_size),
            totalInodes: info.inode_count,
            freeInodes: info.free_inodes)
    }

    func stat(_ path: VolumePath) -> ReadOnlyFileAttributes? {
        guard let fs else { return nil }
        var attr = fs_xfs_attr_t()
        guard path.withCString({ fs_xfs_stat(fs, $0, &attr) }) == 0 else { return nil }
        return ReadOnlyFileAttributes(
            inode: attr.inode,
            mode: UInt32(attr.mode),
            uid: attr.uid,
            gid: attr.gid,
            size: attr.size,
            linkCount: attr.link_count,
            mtime: Int64(attr.mtime),
            fileType: XfsVolume.readOnlyFileType(fromRaw: attr.file_type))
    }

    func walkDirectory(_ path: VolumePath,
                       _ visit: (ReadOnlyDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk {
        guard let fs, let iter = path.withCString({ fs_xfs_dir_open(fs, $0) }) else {
            return .openFailed
        }
        defer { fs_xfs_dir_close(iter) }
        while let de = fs_xfs_dir_next(iter) {
            // The name's bytes, bounded by the array rather than a hand-
            // written capacity (diskjockey#207), and never decoded
            // (diskjockey#219).
            guard let name = DirentName.bytes(of: de.pointee.name) else {
                return .failedPartway
            }
            let entry = ReadOnlyDirectoryEntry(
                name: name,
                inode: de.pointee.inode,
                fileType: XfsVolume.readOnlyFileType(fromRaw: UInt32(de.pointee.file_type)))
            if !visit(entry) { return .finished }
        }
        // NULL here is the end, and the errno is deliberately not asked.
        // fs_xfs_dir_open reads the whole directory before it returns, so
        // dir_next only steps through a list it already holds and has
        // nothing left to fail on. fs_xfs.h says the errno "is 0 at a clean
        // end", but am-fs-xfs 0.8.0 never clears it on success: it still
        // holds whatever the last failed call on this thread left there —
        // an ENOENT from any lookup of a missing name, or a stat the visit
        // above just made — and reading it would turn every listing after
        // one miss into EIO.
        return .finished
    }

    func read(_ path: VolumePath, at offset: UInt64,
              into buffer: UnsafeMutableRawBufferPointer) -> Int64 {
        guard let fs else { return -1 }
        return path.withCString {
            fs_xfs_read_file(fs, $0, buffer.baseAddress, offset, UInt64(buffer.count))
        }
    }

    func write(_ path: VolumePath, at offset: UInt64,
               from buffer: UnsafeRawBufferPointer) -> Int64 {
        guard let fs else { return -1 }
        return path.withCString {
            fs_xfs_write_file(fs, $0, buffer.baseAddress, offset, UInt64(buffer.count))
        }
    }

    func truncate(_ path: VolumePath, to size: UInt64, modified: timespec?) -> Int32 {
        guard let fs else { return -1 }
        // FS_XFS_LEAVE_TIME is INT64_MIN; the macro is not imported.
        let sec = modified.map { Int64($0.tv_sec) } ?? Int64.min
        let nsec = modified.map { UInt32($0.tv_nsec) } ?? 0
        return path.withCString { fs_xfs_truncate(fs, $0, size, sec, nsec) }
    }

    func flush() -> Int32 {
        guard let fs else { return -1 }
        return fs_xfs_flush(fs)
    }

    func create(_ path: VolumePath, mode: UInt16) -> UInt64 {
        guard let fs else { return 0 }
        return path.withCString { fs_xfs_create(fs, $0, mode) }
    }

    func mkdir(_ path: VolumePath, mode: UInt16) -> UInt64 {
        guard let fs else { return 0 }
        return path.withCString { fs_xfs_mkdir(fs, $0, mode) }
    }

    func unlink(_ path: VolumePath) -> Int32 {
        guard let fs else { return -1 }
        return path.withCString { fs_xfs_unlink(fs, $0) }
    }

    func rmdir(_ path: VolumePath) -> Int32 {
        guard let fs else { return -1 }
        return path.withCString { fs_xfs_rmdir(fs, $0) }
    }

    func link(_ source: VolumePath, to destination: VolumePath) -> Int32 {
        guard let fs else { return -1 }
        return source.withCString { src in
            destination.withCString { dst in fs_xfs_link(fs, src, dst) }
        }
    }

    func rename(_ source: VolumePath, to destination: VolumePath, replace: Bool) -> Int32 {
        guard let fs else { return -1 }
        let flags: Int32 = replace ? Int32(FS_XFS_RENAME_REPLACE) : 0
        return source.withCString { src in
            destination.withCString { dst in fs_xfs_rename2(fs, src, dst, flags) }
        }
    }

    func setAttributes(_ path: VolumePath, mode: UInt32?, uid: UInt32?, gid: UInt32?,
                       accessed: timespec?, modified: timespec?) -> Int32 {
        guard let fs else { return -1 }
        // FS_XFS_LEAVE is -1 and FS_XFS_LEAVE_TIME INT64_MIN; neither macro
        // is imported, being casts.
        let leave: Int64 = -1
        return path.withCString {
            fs_xfs_set_attributes(
                fs, $0,
                mode.map { Int64($0) } ?? leave,
                uid.map { Int64($0) } ?? leave,
                gid.map { Int64($0) } ?? leave,
                accessed.map { Int64($0.tv_sec) } ?? Int64.min,
                accessed.map { UInt32($0.tv_nsec) } ?? 0,
                modified.map { Int64($0.tv_sec) } ?? Int64.min,
                modified.map { UInt32($0.tv_nsec) } ?? 0)
        }
    }

    func getXattr(_ path: VolumePath, name: [UInt8]) -> [UInt8]? {
        guard let fs else { return nil }
        return path.withCString { p in
            Self.withCName(name) { n in
                Self.sized { buf, size in fs_xfs_getxattr(fs, p, n, buf, size) }
            }
        }
    }

    func listXattrs(_ path: VolumePath) -> [[UInt8]]? {
        guard let fs else { return nil }
        let names = path.withCString { p in
            Self.sized { buf, size in fs_xfs_listxattr(fs, p, buf, size) }
        }
        return names.map { $0.split(separator: 0).map(Array.init) }
    }

    func setXattr(_ path: VolumePath, name: [UInt8], value: [UInt8], flags: Int32) -> Int32 {
        guard let fs else { return -1 }
        return path.withCString { p in
            Self.withCName(name) { n in
                value.withUnsafeBytes { fs_xfs_setxattr(fs, p, n, $0.baseAddress, $0.count, flags) }
            }
        }
    }

    func removeXattr(_ path: VolumePath, name: [UInt8]) -> Int32 {
        guard let fs else { return -1 }
        return path.withCString { p in
            Self.withCName(name) { n in fs_xfs_removexattr(fs, p, n) }
        }
    }

    /// The size first, then the bytes into a buffer of it. A value that
    /// grew in between is ERANGE, and is asked for again.
    private static func sized(_ call: (UnsafeMutableRawPointer?, Int) -> Int64) -> [UInt8]? {
        for _ in 0..<4 {
            let size = call(nil, 0)
            guard size >= 0 else { return nil }
            if size == 0 { return [] }
            var buffer = [UInt8](repeating: 0, count: Int(size))
            let got = buffer.withUnsafeMutableBytes { call($0.baseAddress, $0.count) }
            if got >= 0 { return Array(buffer.prefix(Int(got))) }
            guard fs_xfs_last_errno() == ERANGE else { return nil }
        }
        return nil
    }

    /// An attribute name as the C string the ABI takes.
    private static func withCName<R>(_ name: [UInt8], _ body: (UnsafePointer<CChar>) -> R) -> R {
        (name + [0]).withUnsafeBufferPointer {
            $0.withMemoryRebound(to: CChar.self) { body($0.baseAddress!) }
        }
    }

    func readlink(_ path: VolumePath, _ buffer: UnsafeMutablePointer<CChar>,
                  _ size: Int) -> Int32 {
        guard let fs else { return -1 }
        return path.withCString { fs_xfs_readlink(fs, $0, buffer, size) }
    }

    func lastErrno() -> Int32 {
        Int32(fs_xfs_last_errno())
    }

    func unmount() {
        if let fs {
            fs_xfs_umount(fs)
            self.fs = nil
        }
    }
}
