/*
 * ErofsDriver.swift — the fs_erofs_* C ABI behind ReadOnlyVolumeDriver.
 *
 * The only file in this extension that calls the driver on behalf of the
 * volume, so that ErofsVolume.swift builds without the Rust static library
 * and `swift test` can run it (DiskJockeyEROFSCore in Package.swift, which
 * excludes this file). Nothing here decides anything: each method is one
 * C call and the conversion of its C types into the shared Swift ones.
 *
 * MIT License — see LICENSE
 */

import Foundation
import DiskJockeyLibrary

final class ErofsDriver: ReadOnlyVolumeDriver {

    private var fs: OpaquePointer?

    init(fs: OpaquePointer) {
        self.fs = fs
    }

    func volumeInfo() -> ReadOnlyVolumeInfo? {
        guard let fs else { return nil }
        var info = fs_erofs_volume_info_t()
        guard fs_erofs_get_volume_info(fs, &info) == 0 else { return nil }
        // EROFS is an immutable image: it counts blocks and has none free.
        return ReadOnlyVolumeInfo(
            capacity: .blocks(blockSize: UInt64(info.block_size),
                              total: UInt64(info.total_blocks),
                              free: 0),
            ioSize: UInt64(info.block_size),
            totalInodes: info.inode_count,
            freeInodes: nil)
    }

    func stat(_ path: VolumePath) -> ReadOnlyFileAttributes? {
        guard let fs else { return nil }
        var attr = fs_erofs_attr_t()
        guard path.withCString({ fs_erofs_stat(fs, $0, &attr) }) == 0 else { return nil }
        return ReadOnlyFileAttributes(
            inode: attr.inode,
            mode: UInt32(attr.mode),
            uid: attr.uid,
            gid: attr.gid,
            size: attr.size,
            linkCount: attr.link_count,
            mtime: Int64(attr.mtime),
            fileType: ErofsVolume.readOnlyFileType(fromRaw: attr.file_type))
    }

    func walkDirectory(_ path: VolumePath,
                       _ visit: (ReadOnlyDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk {
        guard let fs, let iter = path.withCString({ fs_erofs_dir_open(fs, $0) }) else {
            return .openFailed
        }
        defer { fs_erofs_dir_close(iter) }
        while let de = fs_erofs_dir_next(iter) {
            // The name's bytes, bounded by the array rather than a hand-
            // written capacity (diskjockey#207), and never decoded
            // (diskjockey#219).
            guard let name = DirentName.bytes(of: de.pointee.name) else {
                return .failedPartway
            }
            let entry = ReadOnlyDirectoryEntry(
                name: name,
                inode: de.pointee.inode,
                fileType: ErofsVolume.readOnlyFileType(fromRaw: UInt32(de.pointee.file_type)))
            if !visit(entry) { return .finished }
        }
        // NULL here is the end, and the errno is deliberately not asked.
        // fs_erofs_dir_open reads the whole directory before it returns, so
        // dir_next only steps through a list it already holds and has
        // nothing left to fail on. am-fs-erofs 0.2.0's dir_next does not
        // clear the errno either, so it may still hold a failure from a
        // stat the visit above just made.
        return .finished
    }

    func read(_ path: VolumePath, at offset: UInt64,
              into buffer: UnsafeMutableRawBufferPointer) -> Int64 {
        guard let fs else { return -1 }
        return path.withCString {
            fs_erofs_read_file(fs, $0, buffer.baseAddress, offset, UInt64(buffer.count))
        }
    }

    func readlink(_ path: VolumePath, _ buffer: UnsafeMutablePointer<CChar>,
                  _ size: Int) -> Int32 {
        guard let fs else { return -1 }
        return path.withCString { fs_erofs_readlink(fs, $0, buffer, size) }
    }

    func lastErrno() -> Int32 {
        Int32(fs_erofs_last_errno())
    }

    func unmount() {
        if let fs {
            fs_erofs_umount(fs)
            self.fs = nil
        }
    }
}
