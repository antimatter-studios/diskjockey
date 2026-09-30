/*
 * BtrfsDriver.swift — the fs_btrfs_* C ABI behind ReadOnlyVolumeDriver.
 *
 * The only file in this extension that calls the driver on behalf of the
 * volume, so that BtrfsVolume.swift builds without the Rust static library
 * and `swift test` can run it (DiskJockeyBTRFSCore in Package.swift, which
 * excludes this file). Nothing here decides anything: each method is one
 * C call and the conversion of its C types into the shared Swift ones.
 *
 * MIT License — see LICENSE
 */

import Foundation
import DiskJockeyLibrary

final class BtrfsDriver: ReadOnlyVolumeDriver {

    private var fs: OpaquePointer?

    init(fs: OpaquePointer) {
        self.fs = fs
    }

    func volumeInfo() -> ReadOnlyVolumeInfo? {
        guard let fs else { return nil }
        var info = fs_btrfs_volume_info_t()
        guard fs_btrfs_get_volume_info(fs, &info) == 0 else { return nil }
        // Btrfs reports capacity in BYTES rather than blocks, advertises
        // its node size for I/O rather than its sector size, and has no
        // fixed inode table — inodes come from the same pool as data, so
        // there is no total or free count to give. The nil inode counts
        // say that; see ReadOnlyVolumeInfo.
        return ReadOnlyVolumeInfo(
            capacity: .bytes(sectorSize: UInt64(info.sector_size),
                             total: info.total_bytes,
                             used: info.bytes_used),
            ioSize: UInt64(info.node_size),
            totalInodes: nil,
            freeInodes: nil)
    }

    func stat(_ path: VolumePath) -> ReadOnlyFileAttributes? {
        guard let fs else { return nil }
        var attr = fs_btrfs_attr_t()
        guard path.withCString({ fs_btrfs_stat(fs, $0, &attr) }) == 0 else { return nil }
        return ReadOnlyFileAttributes(
            inode: attr.inode,
            mode: attr.mode,
            uid: attr.uid,
            gid: attr.gid,
            size: attr.size,
            linkCount: attr.link_count,
            mtime: Int64(attr.mtime),
            fileType: BtrfsVolume.readOnlyFileType(fromRaw: attr.file_type))
    }

    func walkDirectory(_ path: VolumePath,
                       _ visit: (ReadOnlyDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk {
        guard let fs, let iter = path.withCString({ fs_btrfs_dir_open(fs, $0) }) else {
            return .openFailed
        }
        defer { fs_btrfs_dir_close(iter) }
        while let de = fs_btrfs_dir_next(iter) {
            // The name's bytes, bounded by the array rather than a hand-
            // written capacity (diskjockey#207), and never decoded
            // (diskjockey#219).
            guard let name = DirentName.bytes(of: de.pointee.name) else {
                return .failedPartway
            }
            let entry = ReadOnlyDirectoryEntry(
                name: name,
                inode: de.pointee.inode,
                fileType: BtrfsVolume.readOnlyFileType(fromRaw: UInt32(de.pointee.file_type)),
                isSubvolume: de.pointee.is_subvolume != 0)
            if !visit(entry) { return .finished }
        }
        // NULL here is the end, and the errno is deliberately not asked.
        // fs_btrfs_dir_open reads the whole directory before it returns, so
        // dir_next only steps through a list it already holds and has
        // nothing left to fail on. fs_btrfs.h says the errno "is 0 at a
        // clean end", but am-fs-btrfs 0.7.0 never clears it on success: it
        // still holds whatever the last failed call on this thread left
        // there — an ENOENT from any lookup of a missing name, or a stat
        // the visit above just made — and reading it would turn every
        // listing after one miss into EIO (rust-fs-btrfs#232).
        return .finished
    }

    func read(_ path: VolumePath, at offset: UInt64,
              into buffer: UnsafeMutableRawBufferPointer) -> Int64 {
        guard let fs else { return -1 }
        return path.withCString {
            fs_btrfs_read_file(fs, $0, buffer.baseAddress, offset, UInt64(buffer.count))
        }
    }

    func readlink(_ path: VolumePath, _ buffer: UnsafeMutablePointer<CChar>,
                  _ size: Int) -> Int32 {
        guard let fs else { return -1 }
        return path.withCString { fs_btrfs_readlink(fs, $0, buffer, size) }
    }

    func lastErrno() -> Int32 {
        Int32(fs_btrfs_last_errno())
    }

    func unmount() {
        if let fs {
            fs_btrfs_umount(fs)
            self.fs = nil
        }
    }
}
