/*
 * BcachefsDriver.swift — the fs_bcachefs_* C ABI behind BcachefsBackend.
 *
 * The only file that calls the driver on the volume's behalf. Nothing here
 * decides what an FSKit operation means; each method is the C calls for one
 * backend call and the conversion of their C types.
 *
 * TWO HANDLES, ONE DEVICE. The C ABI reads through a read handle
 * (fs_bcachefs_mount_with_fs_core_device) and writes through a write handle
 * (fs_bcachefs_mount_rw_with_fs_core_device), both on the same fs_core
 * device. A write is committed to the device before it returns, but a read
 * handle opened before it does not see it (fs_bcachefs.h), so the read
 * handle is reopened before the first read after any write. Every call
 * holds one lock, so no read runs while a write is half done.
 *
 * Built in two places: the extension, where the bridging header declares
 * the C ABI, and DiskJockeyBCACHEFSCore under `swift test`, where the
 * CBcachefsBundle module does, linked to the same bundle library.
 *
 * MIT License — see LICENSE
 */

import Foundation
import DiskJockeyLibrary
#if canImport(CBcachefsBundle)
import CBcachefsBundle
#endif

final class BcachefsDriver: BcachefsBackend {

    private let lock = NSRecursiveLock()
    /// The fs_core device both handles read and write through. Owned here:
    /// closed at unmount.
    private var device: OpaquePointer?
    private var readHandle: OpaquePointer?
    private var writeHandle: OpaquePointer?
    /// The errno the driver refused the write handle with, when it did:
    /// every write answers it.
    private(set) var writeRefusal: Int32?
    /// Set by every write: the read handle predates it.
    private var readHandleIsStale = false

    let isWritable: Bool

    /// Takes ownership of `device`. Opens the read handle, and the write
    /// handle when `writable`. Throws the driver's errno when the read
    /// handle cannot be opened; a refused write handle is kept as
    /// `writeRefusal` instead, so a filesystem the driver will not write
    /// still mounts and reads.
    init(device: OpaquePointer, writable: Bool) throws {
        self.device = device
        self.isWritable = writable
        guard let fs = fs_bcachefs_mount_with_fs_core_device(device) else {
            let errno = Self.errno()
            fs_core_device_close(device)
            self.device = nil
            throw Self.error(errno)
        }
        readHandle = fs
        if writable {
            if let rw = fs_bcachefs_mount_rw_with_fs_core_device(device) {
                writeHandle = rw
            } else {
                writeRefusal = Self.errno()
            }
        }
    }

    deinit { unmount() }

    /// The driver's message for this thread's last failure.
    static func lastErrorMessage() -> String {
        fs_bcachefs_last_error().map { String(cString: $0) } ?? ""
    }

    private static func errno() -> Int32 {
        let e = Int32(fs_bcachefs_last_errno())
        return e > 0 ? e : EIO
    }

    private static func error(_ errno: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    // MARK: - Handles

    /// Runs `body` on a read handle that has seen every write.
    private func reading<T>(_ failed: T, _ body: (OpaquePointer) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        if readHandleIsStale || readHandle == nil {
            if let fs = readHandle { fs_bcachefs_umount(fs) }
            readHandle = nil
            guard let device, let fs = fs_bcachefs_mount_with_fs_core_device(device) else {
                return failed
            }
            readHandle = fs
            readHandleIsStale = false
        }
        guard let fs = readHandle else { return failed }
        return body(fs)
    }

    /// Runs one write: 0 or the driver's negative errno. Without a write
    /// handle it answers the refusal's errno, or EROFS on a read-only
    /// mount.
    private func writing(_ body: (OpaquePointer) -> Int32) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard let rw = writeHandle else {
            return -(writeRefusal ?? EROFS)
        }
        let rc = body(rw)
        readHandleIsStale = true
        return rc
    }

    // MARK: - Reading

    /// The volume's label, empty when it has none.
    func label() -> String {
        reading("") { fs in
            var info = fs_bcachefs_volume_info_t()
            guard fs_bcachefs_get_volume_info(fs, &info) == 0 else { return "" }
            return withUnsafeBytes(of: info.label) { raw in
                let bytes = raw.prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }
        }
    }

    func volumeInfo() -> BcachefsVolumeInfo? {
        reading(nil) { fs in
            var st = fs_bcachefs_statfs_t()
            guard fs_bcachefs_statfs(fs, &st) == 0 else { return nil }
            return BcachefsVolumeInfo(blockSize: st.block_size, bucketSize: st.bucket_size,
                                      totalBytes: st.total_bytes, freeBytes: st.free_bytes)
        }
    }

    func stat(_ path: VolumePath) -> BcachefsFileAttributes? {
        reading(nil) { fs in
            var a = fs_bcachefs_attr_t()
            var t = fs_bcachefs_times_t()
            let ok = path.withCString { p in
                fs_bcachefs_stat(fs, p, &a) == 0 && fs_bcachefs_stat_times(fs, p, &t) == 0
            }
            guard ok else { return nil }
            return BcachefsFileAttributes(
                inode: a.ino, mode: a.mode, linkCount: a.nlink, uid: a.uid, gid: a.gid,
                size: a.size, sectors: a.sectors,
                accessTime: BcachefsTime(seconds: t.atime_sec, nanoseconds: t.atime_nsec),
                modifyTime: BcachefsTime(seconds: t.mtime_sec, nanoseconds: t.mtime_nsec),
                changeTime: BcachefsTime(seconds: t.ctime_sec, nanoseconds: t.ctime_nsec))
        }
    }

    func walkDirectory(_ path: VolumePath,
                       _ visit: (BcachefsDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk {
        // The listing is copied out under the lock, then offered: `visit`
        // may stat each entry, and a read handle reopened meanwhile would
        // free the iterator under it.
        let listed: (entries: [BcachefsDirectoryEntry], complete: Bool)? = reading(nil) { fs in
            guard let it = path.withCString({ fs_bcachefs_dir_open(fs, $0) }) else { return nil }
            defer { fs_bcachefs_dir_close(it) }
            var out: [BcachefsDirectoryEntry] = []
            while let de = fs_bcachefs_dir_next(it) {
                // By name_len, never by scanning for the NUL, and never
                // decoded (diskjockey#207, #219). A name that cannot be
                // read ends the listing as a failure.
                guard let name = DirentName.bytes(of: de.pointee.name,
                                                  length: Int(de.pointee.name_len)) else {
                    return (out, false)
                }
                out.append(BcachefsDirectoryEntry(
                    name: name, inode: de.pointee.ino,
                    fileType: BcachefsFileType(dType: de.pointee.d_type)))
            }
            return (out, true)
        }
        guard let listed else { return .openFailed }
        for entry in listed.entries where !visit(entry) {
            return .finished
        }
        return listed.complete ? .finished : .failedPartway
    }

    func read(_ path: VolumePath, at offset: UInt64,
              into buffer: UnsafeMutableRawBufferPointer) -> Int64 {
        reading(-1) { fs in
            path.withCString {
                fs_bcachefs_read_file(fs, $0, buffer.baseAddress, offset, UInt64(buffer.count))
            }
        }
    }

    /// A length-query call (len 0 answers the size), then the call that
    /// fills a buffer of that size.
    private func sized(_ call: (UnsafeMutableRawPointer?, UInt64) -> Int64) -> [UInt8]? {
        let need = call(nil, 0)
        guard need >= 0 else { return nil }
        if need == 0 { return [] }
        var bytes = [UInt8](repeating: 0, count: Int(need))
        let got = bytes.withUnsafeMutableBytes { call($0.baseAddress, UInt64($0.count)) }
        guard got >= 0 else { return nil }
        return Array(bytes.prefix(Int(got)))
    }

    func readlink(_ path: VolumePath) -> [UInt8]? {
        reading(nil) { fs in
            path.withCString { p in sized { fs_bcachefs_readlink(fs, p, $0, $1) } }
        }
    }

    func listXattrs(_ path: VolumePath) -> [[UInt8]]? {
        reading(nil) { fs in
            guard let all = path.withCString({ p in sized { fs_bcachefs_listxattr(fs, p, $0, $1) } })
            else { return nil }
            return all.split(separator: 0, omittingEmptySubsequences: true).map(Array.init)
        }
    }

    func getXattr(_ path: VolumePath, name: [UInt8]) -> [UInt8]? {
        reading(nil) { fs in
            path.withCString { p in
                Self.withCString(name) { n in sized { fs_bcachefs_getxattr(fs, p, n, $0, $1) } }
            }
        }
    }

    // MARK: - Writing

    func create(_ path: VolumePath, mode: UInt32) -> Int32 {
        writing { rw in path.withCString { fs_bcachefs_create(rw, $0, nil, 0, mode) } }
    }

    func mkdir(_ path: VolumePath, mode: UInt32) -> Int32 {
        writing { rw in path.withCString { fs_bcachefs_mkdir(rw, $0, mode) } }
    }

    func unlink(_ path: VolumePath) -> Int32 {
        writing { rw in path.withCString { fs_bcachefs_unlink(rw, $0) } }
    }

    func rmdir(_ path: VolumePath) -> Int32 {
        writing { rw in path.withCString { fs_bcachefs_rmdir(rw, $0) } }
    }

    func rename(_ from: VolumePath, to: VolumePath) -> Int32 {
        writing { rw in
            from.withCString { f in to.withCString { t in fs_bcachefs_rename(rw, f, t) } }
        }
    }

    func symlink(_ path: VolumePath, target: [UInt8]) -> Int32 {
        writing { rw in
            path.withCString { p in Self.withCString(target) { fs_bcachefs_symlink(rw, p, $0) } }
        }
    }

    func link(_ existing: VolumePath, to path: VolumePath) -> Int32 {
        writing { rw in
            existing.withCString { e in path.withCString { fs_bcachefs_link(rw, e, $0) } }
        }
    }

    func writeFile(_ path: VolumePath, _ bytes: UnsafeRawBufferPointer) -> Int32 {
        writing { rw in
            path.withCString {
                fs_bcachefs_write_file(rw, $0, bytes.isEmpty ? nil : bytes.baseAddress,
                                       UInt64(bytes.count))
            }
        }
    }

    func chmod(_ path: VolumePath, mode: UInt32) -> Int32 {
        writing { rw in path.withCString { fs_bcachefs_chmod(rw, $0, mode) } }
    }

    func chown(_ path: VolumePath, uid: UInt32, gid: UInt32) -> Int32 {
        writing { rw in path.withCString { fs_bcachefs_chown(rw, $0, uid, gid) } }
    }

    func setXattr(_ path: VolumePath, name: [UInt8], value: [UInt8]) -> Int32 {
        writing { rw in
            path.withCString { p in
                Self.withCString(name) { n in
                    value.withUnsafeBytes {
                        fs_bcachefs_setxattr(rw, p, n, value.isEmpty ? nil : $0.baseAddress,
                                             UInt64(value.count))
                    }
                }
            }
        }
    }

    func removeXattr(_ path: VolumePath, name: [UInt8]) -> Int32 {
        writing { rw in
            path.withCString { p in Self.withCString(name) { fs_bcachefs_removexattr(rw, p, $0) } }
        }
    }

    func lastErrno() -> Int32 {
        Int32(fs_bcachefs_last_errno())
    }

    func unmount() {
        lock.lock()
        defer { lock.unlock() }
        if let rw = writeHandle { fs_bcachefs_rw_close(rw) }
        writeHandle = nil
        if let fs = readHandle { fs_bcachefs_umount(fs) }
        readHandle = nil
        if let device { fs_core_device_close(device) }
        device = nil
    }

    /// `bytes` as a NUL-terminated C string for the length of `body`.
    private static func withCString<T>(_ bytes: [UInt8], _ body: (UnsafePointer<CChar>) -> T) -> T {
        (bytes + [0]).withUnsafeBufferPointer { buf in
            buf.withMemoryRebound(to: CChar.self) { body($0.baseAddress!) }
        }
    }
}
