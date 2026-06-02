//
// DeviceContexts.swift — FFI bridge contexts that adapt FSKit
// resources to the C-callback shape Rust filesystem drivers expect.
//
// Two concrete contexts wrap the two resource kinds FSKit hands an
// `FSUnaryFileSystem`:
//
//   • `BlockDeviceContext` — `FSBlockDeviceResource` (a real disk
//     partition). Reads + writes are block-size aligned; flush goes
//     through `metadataFlush()`.
//   • `FileDeviceContext` — `FSPathURLResource` (a path-mounted disk
//     image file). Uses `pread`/`pwrite`/`fsync` against an
//     `O_RDWR`/`O_RDONLY` fd.
//
// `DeviceReadable` is the common interface so cross-resource-kind
// callers (container detection, fs_core callback closures) can be
// written once and dispatched into whichever concrete context is in
// use at load time.
//
// Originally lived in `DiskJockeyEXT4/EXT4DeviceContext.swift`;
// promoted to DiskJockeyLibrary so future filesystems (NTFS file-
// backed mounts when those land, or a third FS family) can reuse
// the same wrappers without forking. The classes themselves are
// FS-agnostic — every method is plumbing over FSKit + Foundation.
//

import FSKit
import Foundation

/// Common interface for both block-device and file-backed I/O contexts.
/// Lets `detectContainer`-style probes and the `FsCoreCallbackCfg`
/// callback closures dispatch generically into whichever concrete
/// context is in use.
public protocol DeviceReadable: AnyObject {
    func read(into buf: UnsafeMutableRawPointer, offset: off_t, length: Int) -> Int32
}

/// Minimum sector size guaranteed by ATA/NVMe spec; used as the
/// floor when the device reports 0 for its block size.
private let minSectorBytes = 512

/// Selects which FSBlockDeviceResource write API the context's
/// `write` method dispatches to. The two have different
/// commit-timing semantics:
///
///   - `.delayed` calls `delayedMetadataWrite(...)` — queued in the
///     kernel buffer cache; `flush()` is what actually commits to
///     the device. Used by ext4, whose Rust crate batches metadata
///     writes and explicitly flushes when needed.
///
///   - `.immediate` calls `metadataWrite(...)` — synchronous; the
///     bytes are on the device when the call returns. Used by NTFS,
///     whose `fs_ntfs_blockdev_cfg_t` callback contract assumes the
///     write has hit the disk before the next call.
///
/// Picking the wrong strategy results in writes either silently
/// queueing (`.delayed` for an FS that expects immediate commit) or
/// adding round-trip latency (`.immediate` for an FS that batches).
public enum BlockDeviceWriteStrategy: Sendable {
    case delayed
    case immediate
}

/// Wraps `FSBlockDeviceResource` for C-callback access.
/// `FSBlockDeviceResource.read` requires offset+length aligned to
/// blockSize; we align to the block size and copy the requested
/// window out of the read buffer.
///
/// The `log` property is a subject-tagged logger (carrying
/// `fields["bsd"]=<disk>`) injected at construction time. The
/// `@convention(c)` closures used by the driver FFI can't capture
/// Swift state, so they dispatch into this class via an `Unmanaged`
/// pointer and the actual logging happens here where regular Swift
/// capture semantics apply.
///
/// Per-FS knobs (constructor parameters, all with EXT4-preserving
/// defaults):
///
///   - `stats` — optional so probe-time contexts that don't have an
///     `IOStatsCollector` yet (NTFS does a short-lived probe pass
///     before the long-lived mount context exists) can pass nil
///     instead of fabricating a collector.
///
///   - `writeStrategy` — `.delayed` (default, EXT4 behaviour) or
///     `.immediate` (NTFS). See `BlockDeviceWriteStrategy`.
///
///   - `readCache` — opt-in in-process read cache (NTFS opts in to
///     dodge redundant boot-sector + $UpCase fetches; EXT4 leaves
///     nil because its Rust crate retains state across operations).
///     Reads consult the cache before hitting the device; writes
///     invalidate any overlapping cached range.
///
///   - `alignToPhysicalBlockSize` — `true` (default, EXT4) aligns
///     writes to `max(logicalBs, physicalBs, 512)` for sector-
///     addressed devices; `false` (NTFS) aligns to `max(logicalBs,
///     512)` because the NTFS write path doesn't share EXT4's
///     physical-block requirement.
public final class BlockDeviceContext: DeviceReadable {
    public let resource: FSBlockDeviceResource
    public let blockSize: Int
    public let log: TaggedLogger
    /// Records bytes/ops/latency for every callback the FS driver
    /// makes to the underlying block device. Distinct from any
    /// file-level stats kept by the volume — these are *physical*
    /// I/O numbers, inflated by metadata reads, journal writes, and
    /// block alignment. Optional so probe-only contexts (no live
    /// recorder yet) can omit it.
    public let stats: IOStatsCollector?
    public let writeStrategy: BlockDeviceWriteStrategy
    public let readCache: BlockReadCache?
    public let alignToPhysicalBlockSize: Bool

    public init(
        resource: FSBlockDeviceResource,
        log: TaggedLogger,
        stats: IOStatsCollector? = nil,
        writeStrategy: BlockDeviceWriteStrategy = .delayed,
        readCache: BlockReadCache? = nil,
        alignToPhysicalBlockSize: Bool = true
    ) {
        self.resource = resource
        self.blockSize = Int(resource.blockSize)
        self.log = log
        self.stats = stats
        self.writeStrategy = writeStrategy
        self.readCache = readCache
        self.alignToPhysicalBlockSize = alignToPhysicalBlockSize
    }

    public func read(into buf: UnsafeMutableRawPointer, offset: off_t, length: Int) -> Int32 {
        let bs = max(blockSize, minSectorBytes)
        let alignedOffset = (Int(offset) / bs) * bs
        let offsetDelta = Int(offset) - alignedOffset
        let alignedLength = ((offsetDelta + length + bs - 1) / bs) * bs

        // Cache hit: copy the requested window out of the cached
        // aligned region. No device round-trip; no stats recorded
        // (the cache fast path is a free read by construction).
        if let cache = readCache,
           let cached = cache.lookup(offset: alignedOffset, length: alignedLength) {
            cached.withUnsafeBufferPointer { ptr in
                memcpy(buf, ptr.baseAddress!.advanced(by: offsetDelta), length)
            }
            return 0
        }

        let tmp = UnsafeMutableRawPointer.allocate(byteCount: alignedLength, alignment: bs)
        defer { tmp.deallocate() }

        let t0 = monotonicNanos()
        do {
            let rawBuf = UnsafeMutableRawBufferPointer(start: tmp, count: alignedLength)
            let bytesRead = try resource.read(into: rawBuf, startingAt: off_t(alignedOffset), length: alignedLength)
            if bytesRead < offsetDelta + length {
                log.error("bdev read short: off=\(offset) len=\(length) alignedOff=\(alignedOffset) alignedLen=\(alignedLength) got=\(bytesRead)", scope: AppLogScope.io)
                stats?.recordBdevRead(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
                return EIO
            }
            // Populate the cache before copying out so a concurrent
            // reader picking up the same window benefits immediately.
            if let cache = readCache {
                let bytes = Array(UnsafeBufferPointer(
                    start: tmp.assumingMemoryBound(to: UInt8.self),
                    count: alignedLength))
                cache.insert(offset: alignedOffset, length: alignedLength, bytes: bytes)
            }
            memcpy(buf, tmp.advanced(by: offsetDelta), length)
            stats?.recordBdevRead(bytes: alignedLength, latencyNs: monotonicNanos() &- t0, error: false)
            return 0
        } catch {
            log.error("bdev read error: off=\(offset) len=\(length) err=\(error.localizedDescription)", scope: AppLogScope.io)
            stats?.recordBdevRead(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
            return EIO
        }
    }

    /// Mirror image of `read`. `FSBlockDeviceResource.write` requires
    /// the same block-size alignment as read, so we read-modify-write
    /// the partially-overlapping head and tail blocks when the
    /// requested window doesn't sit on a block boundary.
    public func write(from buf: UnsafeRawPointer, offset: off_t, length: Int) -> Int32 {
        // Alignment choice depends on `alignToPhysicalBlockSize`:
        // EXT4 defaults to true (kernel buffer cache requires
        // `physicalBlockSize`-aligned ops for sector-addressed
        // devices); NTFS passes false because its write path doesn't
        // share that requirement.
        let logicalBs = Int(resource.blockSize)
        let bs: Int = alignToPhysicalBlockSize
            ? max(logicalBs, Int(resource.physicalBlockSize), minSectorBytes)
            : max(logicalBs, minSectorBytes)
        let alignedOffset = (Int(offset) / bs) * bs
        let offsetDelta = Int(offset) - alignedOffset
        let alignedLength = ((offsetDelta + length + bs - 1) / bs) * bs

        let tmp = UnsafeMutableRawPointer.allocate(byteCount: alignedLength, alignment: bs)
        defer { tmp.deallocate() }

        // Read the surrounding aligned window when the caller's window
        // doesn't cover it fully (so we don't overwrite untouched bytes).
        // Use plain `read` (verified to work during loadResource), not
        // `metadataRead` (returns EIO during loadResource on at least
        // some devices).
        let t0 = monotonicNanos()
        do {
            let needsHead = offsetDelta != 0
            let needsTail = (offsetDelta + length) != alignedLength
            if needsHead || needsTail {
                let rawBuf = UnsafeMutableRawBufferPointer(start: tmp, count: alignedLength)
                let bytesRead = try resource.read(into: rawBuf,
                                                  startingAt: off_t(alignedOffset),
                                                  length: alignedLength)
                if bytesRead < alignedLength {
                    memset(tmp.advanced(by: bytesRead), 0, alignedLength - bytesRead)
                }
            }
            memcpy(tmp.advanced(by: offsetDelta), buf, length)

            let writeBuf = UnsafeRawBufferPointer(start: tmp, count: alignedLength)
            switch writeStrategy {
            case .delayed:
                try resource.delayedMetadataWrite(from: writeBuf,
                                                  startingAt: off_t(alignedOffset),
                                                  length: alignedLength)
            case .immediate:
                try resource.metadataWrite(from: writeBuf,
                                           startingAt: off_t(alignedOffset),
                                           length: alignedLength)
            }
            // Invalidate any cached read that overlaps the written
            // region. Sectors entirely outside the write stay cached.
            readCache?.invalidate(rangeOffset: alignedOffset, length: alignedLength)
            log.info("bdev write ok: off=\(offset) len=\(length) alignedOff=\(alignedOffset) alignedLen=\(alignedLength)", scope: AppLogScope.io)
            stats?.recordBdevWrite(bytes: alignedLength, latencyNs: monotonicNanos() &- t0, error: false)
            return 0
        } catch {
            let apiName = writeStrategy == .delayed ? "delayedMetadataWrite" : "metadataWrite"
            log.error("bdev \(apiName) error: off=\(offset) len=\(length) alignedOff=\(alignedOffset) alignedLen=\(alignedLength) bs=\(bs) err=\(error.localizedDescription)", scope: AppLogScope.io)
            stats?.recordBdevWrite(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
            return EIO
        }
    }

    /// Flush the kernel buffer cache to disk. With `metadataWrite`,
    /// `metadataFlush()` is meaningful — it forces any cached
    /// metadata blocks (including ones the FS driver just wrote) out
    /// to the device.
    public func flush() -> Int32 {
        do {
            try resource.metadataFlush()
            return 0
        } catch {
            log.error("bdev metadataFlush error: \(error.localizedDescription)", scope: AppLogScope.io)
            return EIO
        }
    }
}

/// File-backed I/O context for `FSPathURLResource` mounts. Analogous
/// to `BlockDeviceContext` but reads/writes a plain file via
/// `pread`/`pwrite`. Used when fskitd invokes
/// `mount -F -t <fs> /path/to/file.qcow2 /Volumes/<name>`.
public final class FileDeviceContext: DeviceReadable {
    public let fileURL: URL
    public let fileSize: UInt64
    public let writable: Bool
    public let log: TaggedLogger
    public let stats: IOStatsCollector
    private let fd: Int32
    private let securityScoped: Bool

    public init(url: URL, writable: Bool, log: TaggedLogger, stats: IOStatsCollector) throws {
        self.fileURL = url
        self.writable = writable
        self.log = log
        self.stats = stats
        self.securityScoped = url.startAccessingSecurityScopedResource()
        let flags: Int32 = writable ? O_RDWR : O_RDONLY
        let descriptor = Darwin.open(url.path, flags)
        guard descriptor >= 0 else {
            if securityScoped { url.stopAccessingSecurityScopedResource() }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }
        self.fd = descriptor
        var st = Darwin.stat()
        guard Darwin.fstat(descriptor, &st) == 0 else {
            Darwin.close(descriptor)
            if securityScoped { url.stopAccessingSecurityScopedResource() }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.fileSize = UInt64(bitPattern: Int64(st.st_size))
    }

    deinit {
        Darwin.close(fd)
        if securityScoped { fileURL.stopAccessingSecurityScopedResource() }
    }

    public func read(into buf: UnsafeMutableRawPointer, offset: off_t, length: Int) -> Int32 {
        let t0 = monotonicNanos()
        let n = pread(fd, buf, length, offset)
        if n < 0 || n < length {
            log.error("file read short: off=\(offset) len=\(length) got=\(n)", scope: AppLogScope.io)
            stats.recordBdevRead(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
            return EIO
        }
        stats.recordBdevRead(bytes: length, latencyNs: monotonicNanos() &- t0, error: false)
        return 0
    }

    public func write(from buf: UnsafeRawPointer, offset: off_t, length: Int) -> Int32 {
        let t0 = monotonicNanos()
        let n = pwrite(fd, buf, length, offset)
        if n < 0 || n < length {
            log.error("file write short: off=\(offset) len=\(length) got=\(n)", scope: AppLogScope.io)
            stats.recordBdevWrite(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
            return EIO
        }
        stats.recordBdevWrite(bytes: length, latencyNs: monotonicNanos() &- t0, error: false)
        return 0
    }

    public func flush() -> Int32 {
        return Darwin.fsync(fd) == 0 ? 0 : EIO
    }
}
