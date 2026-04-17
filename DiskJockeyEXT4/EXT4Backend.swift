/*
 * EXT4Backend.swift — FileSystemBackend wrapping the lwext4 C bridge.
 *
 * Translates protocol calls to ext4rs_* C functions.
 *
 * MIT License — see LICENSE
 */

import Foundation
import os

private let backendLogger = Logger(subsystem: "com.antimatterstudios.ext4-fskit", category: "backend")

final class EXT4Backend: FileSystemBackend {

    private var bridgeFS: OpaquePointer?
    // lwext4 is not thread-safe; serialize all C bridge calls.
    private let lock = NSLock()

    init(bridgeFS: OpaquePointer) {
        self.bridgeFS = bridgeFS
    }

    func volumeInfo() -> BackendVolumeInfo {
        lock.lock(); defer { lock.unlock() }
        guard let fs = bridgeFS else {
            return BackendVolumeInfo(name: "ext4", blockSize: 4096,
                                    totalBlocks: 0, freeBlocks: 0,
                                    totalInodes: 0, freeInodes: 0)
        }

        var info = ext4rs_volume_info_t()
        ext4rs_get_volume_info(fs, &info)

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
            freeInodes: info.free_inodes
        )
    }

    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        if let fs = bridgeFS {
            ext4rs_umount(fs)
            bridgeFS = nil
        }
    }

    func stat(path: String) -> BackendFileAttributes? {
        lock.lock(); defer { lock.unlock() }
        guard let fs = bridgeFS else { return nil }

        var attr = ext4rs_attr_t()
        let rc = ext4rs_stat(fs, path, &attr)
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

    func readDirectory(path: String) -> [BackendDirectoryEntry]? {
        lock.lock(); defer { lock.unlock() }
        guard let fs = bridgeFS else {
            backendLogger.error("readDirectory(\(path, privacy: .public)): bridgeFS is nil")
            return nil
        }

        guard let iter = ext4rs_dir_open(fs, path) else {
            backendLogger.error("readDirectory(\(path, privacy: .public)): ext4rs_dir_open returned nil")
            return nil
        }
        defer { ext4rs_dir_close(iter) }

        var entries: [BackendDirectoryEntry] = []
        while let de = ext4rs_dir_next(iter) {
            let name = withUnsafePointer(to: de.pointee.name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 256) { cstr in
                    String(cString: cstr)
                }
            }
            entries.append(BackendDirectoryEntry(
                fileID: UInt64(de.pointee.inode),
                fileType: Self.convertFileType(
                    ext4rs_file_type_t(rawValue: UInt32(de.pointee.file_type))),
                name: name
            ))
        }
        backendLogger.error("readDirectory(\(path, privacy: .public)): returning \(entries.count) entries")
        return entries
    }

    func readFile(path: String, offset: UInt64, length: UInt64,
                  buffer: UnsafeMutableRawPointer) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let fs = bridgeFS else { return -1 }
        return ext4rs_read_file(fs, path, buffer, offset, length)
    }

    func readSymlink(path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let fs = bridgeFS else { return nil }

        var buf = [CChar](repeating: 0, count: 4096)
        let rc = ext4rs_readlink(fs, path, &buf, buf.count)
        guard rc == 0 else { return nil }

        return String(cString: buf)
    }

    // MARK: - Helpers

    private static func convertFileType(_ bridgeType: ext4rs_file_type_t) -> BackendFileType {
        switch bridgeType {
        case EXT4RS_FT_REG_FILE: return .file
        case EXT4RS_FT_DIR:      return .directory
        case EXT4RS_FT_SYMLINK:  return .symlink
        case EXT4RS_FT_CHRDEV:   return .charDevice
        case EXT4RS_FT_BLKDEV:   return .blockDevice
        case EXT4RS_FT_FIFO:     return .fifo
        case EXT4RS_FT_SOCK:     return .socket
        default:                       return .unknown
        }
    }
}
