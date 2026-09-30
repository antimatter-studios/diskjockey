/*
 * SquashfsDriver.swift — the fs_squashfs_* C ABI behind ReadOnlyVolumeDriver.
 *
 * The only file in this extension that calls the driver on behalf of the
 * volume, so that SquashfsVolume.swift builds without the Rust static library
 * and `swift test` can run it (DiskJockeySQUASHFSCore in Package.swift, which
 * excludes this file). Nothing here decides anything: each method is one
 * C call and the conversion of its C types into the shared Swift ones.
 *
 * MIT License — see LICENSE
 */

import Foundation
import DiskJockeyLibrary

final class SquashfsDriver: ReadOnlyVolumeDriver {

    private var fs: OpaquePointer?

    init(fs: OpaquePointer) {
        self.fs = fs
    }

    func volumeInfo() -> ReadOnlyVolumeInfo? {
        guard let fs else { return nil }
        var info = fs_squashfs_volume_info_t()
        guard fs_squashfs_get_volume_info(fs, &info) == 0 else { return nil }
        // A SquashFS image is exactly as large as its contents and
        // cannot grow, so used is total and nothing is free.
        return ReadOnlyVolumeInfo(
            capacity: .compressedImage(blockSize: UInt64(info.block_size),
                                       usedBytes: info.bytes_used),
            ioSize: UInt64(info.block_size),
            totalInodes: UInt64(info.inode_count),
            freeInodes: nil)
    }

    func stat(_ path: VolumePath) -> ReadOnlyFileAttributes? {
        guard let fs else { return nil }
        var attr = fs_squashfs_attr_t()
        guard path.withCString({ fs_squashfs_stat(fs, $0, &attr) }) == 0 else { return nil }
        return ReadOnlyFileAttributes(
            inode: UInt64(attr.inode),
            mode: UInt32(attr.mode),
            uid: attr.uid,
            gid: attr.gid,
            size: attr.size,
            linkCount: attr.link_count,
            mtime: Int64(attr.mtime),
            fileType: SquashfsVolume.readOnlyFileType(fromRaw: attr.file_type))
    }

    func walkDirectory(_ path: VolumePath,
                       _ visit: (ReadOnlyDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk {
        guard let fs, let iter = path.withCString({ fs_squashfs_dir_open(fs, $0) }) else {
            return .openFailed
        }
        defer { fs_squashfs_dir_close(iter) }
        while let de = fs_squashfs_dir_next(iter) {
            // By `name_len`, not by scanning for the NUL: a SquashFS name
            // can be 256 bytes, the whole of what the array holds before
            // its terminator (diskjockey#207). Never decoded
            // (diskjockey#219).
            guard let name = DirentName.bytes(
                of: de.pointee.name, length: Int(de.pointee.name_len)) else {
                return .failedPartway
            }
            let entry = ReadOnlyDirectoryEntry(
                name: name,
                inode: UInt64(de.pointee.inode),
                fileType: SquashfsVolume.readOnlyFileType(fromRaw: UInt32(de.pointee.file_type)))
            if !visit(entry) { return .finished }
        }
        // NULL here is the end, and the errno is deliberately not asked.
        // fs_squashfs_dir_open reads the whole directory before it returns, so
        // dir_next only steps through a list it already holds and has
        // nothing left to fail on. am-fs-squashfs 0.2.0's dir_next does
        // not clear the errno either, so it may still hold a failure from
        // a stat the visit above just made.
        return .finished
    }

    func read(_ path: VolumePath, at offset: UInt64,
              into buffer: UnsafeMutableRawBufferPointer) -> Int64 {
        guard let fs else { return -1 }
        return path.withCString {
            fs_squashfs_read_file(fs, $0, buffer.baseAddress, offset, UInt64(buffer.count))
        }
    }

    func readlink(_ path: VolumePath, _ buffer: UnsafeMutablePointer<CChar>,
                  _ size: Int) -> Int32 {
        guard let fs else { return -1 }
        return path.withCString { fs_squashfs_readlink(fs, $0, buffer, size) }
    }

    func lastErrno() -> Int32 {
        Int32(fs_squashfs_last_errno())
    }

    func unmount() {
        if let fs {
            fs_squashfs_umount(fs)
            self.fs = nil
        }
    }
}
