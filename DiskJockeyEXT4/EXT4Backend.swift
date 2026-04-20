/*
 * EXT4Backend.swift — FileSystemBackend wrapping the fs_ext4 C ABI.
 *
 * Translates protocol calls to fs_ext4_* functions exposed by libfs_ext4.a.
 * The fs_ext4 library is built from vendored source at vendor/rust-fs-ext4/
 * (git submodule) and output to vendor/fs_ext4/ via `make vendor-fs-ext4`.
 *
 * MIT License — see LICENSE
 */

import Foundation
import os

private let backendLogger = Logger(subsystem: "com.antimatterstudios.diskjockey.ext4", category: "backend")

final class EXT4Backend: FileSystemBackend {

    /// fs_ext4 serialises per-handle via Arc<RwLock> internally, but we still
    /// hold the handle + a matching Sendable-safe lock on the Swift side so
    /// the class is safe to hand across actor boundaries under Swift 6.
    /// The unfair lock guards `bridgeFS`; the closure body stays synchronous
    /// by construction (no `await`).
    private let state: OSAllocatedUnfairLock<OpaquePointer?>

    init(bridgeFS: OpaquePointer) {
        self.state = OSAllocatedUnfairLock(initialState: bridgeFS)
    }

    func volumeInfo() -> BackendVolumeInfo {
        state.withLock { fs in
            guard let fs = fs else {
                return BackendVolumeInfo(name: "ext4", blockSize: 4096,
                                        totalBlocks: 0, freeBlocks: 0,
                                        totalInodes: 0, freeInodes: 0,
                                        mountedDirty: false)
            }

            var info = fs_ext4_volume_info_t()
            fs_ext4_get_volume_info(fs, &info)

            let name = withUnsafePointer(to: info.volume_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 16) { cstr in
                    String(cString: cstr)
                }
            }

            return BackendVolumeInfo(
                name: name.isEmpty ? "ext4" : name,
                blockSize: info.block_size,
                totalBlocks: info.total_blocks,
                freeBlocks: info.free_blocks,
                totalInodes: info.total_inodes,
                freeInodes: info.free_inodes,
                mountedDirty: info.mounted_dirty != 0
            )
        }
    }

    func shutdown() {
        state.withLock { fs in
            if let handle = fs {
                fs_ext4_umount(handle)
                fs = nil
            }
        }
    }

    func stat(path: String) -> BackendFileAttributes? {
        state.withLock { fs in
            guard let fs = fs else { return nil }

            var attr = fs_ext4_attr_t()
            let rc = fs_ext4_stat(fs, path, &attr)
            guard rc == 0 else { return nil }

            return BackendFileAttributes(
                fileID: UInt64(attr.inode),
                fileType: Self.convertFileType(attr.file_type),
                mode: attr.mode,
                uid: attr.uid,
                gid: attr.gid,
                size: attr.size,
                linkCount: attr.link_count,
                atime: attr.atime,
                mtime: attr.mtime,
                ctime: attr.ctime,
                crtime: attr.crtime
            )
        }
    }

    func readDirectory(path: String) -> [BackendDirectoryEntry]? {
        state.withLock { fs in
            guard let fs = fs else {
                backendLogger.error("readDirectory(\(path)): bridgeFS is nil")
                return nil
            }

            guard let iter = fs_ext4_dir_open(fs, path) else {
                backendLogger.error("readDirectory(\(path)): fs_ext4_dir_open returned nil")
                return nil
            }
            defer { fs_ext4_dir_close(iter) }

            var entries: [BackendDirectoryEntry] = []
            while let de = fs_ext4_dir_next(iter) {
                let name = withUnsafePointer(to: de.pointee.name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: 256) { cstr in
                        String(cString: cstr)
                    }
                }
                entries.append(BackendDirectoryEntry(
                    fileID: UInt64(de.pointee.inode),
                    fileType: Self.convertFileType(
                        fs_ext4_file_type_t(rawValue: UInt32(de.pointee.file_type))),
                    name: name
                ))
            }
            backendLogger.error("readDirectory(\(path)): returning \(entries.count) entries")
            return entries
        }
    }

    func readFile(path: String, offset: UInt64, length: UInt64,
                  buffer: UnsafeMutableRawPointer) -> Int64 {
        state.withLock { fs in
            guard let fs = fs else { return Int64(-1) }
            return fs_ext4_read_file(fs, path, buffer, offset, length)
        }
    }

    func readSymlink(path: String) -> String? {
        state.withLock { fs -> String? in
            guard let fs = fs else { return nil }

            var buf = [CChar](repeating: 0, count: 4096)
            let rc = fs_ext4_readlink(fs, path, &buf, buf.count)
            guard rc == 0 else { return nil }

            return String(cString: buf)
        }
    }

    // MARK: - Helpers

    private static func convertFileType(_ bridgeType: fs_ext4_file_type_t) -> BackendFileType {
        switch bridgeType {
        case FS_EXT4_FT_REG_FILE: return .file
        case FS_EXT4_FT_DIR:      return .directory
        case FS_EXT4_FT_SYMLINK:  return .symlink
        case FS_EXT4_FT_CHRDEV:   return .charDevice
        case FS_EXT4_FT_BLKDEV:   return .blockDevice
        case FS_EXT4_FT_FIFO:     return .fifo
        case FS_EXT4_FT_SOCK:     return .socket
        default:                       return .unknown
        }
    }
}
