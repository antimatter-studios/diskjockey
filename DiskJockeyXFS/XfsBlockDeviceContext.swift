// The XFS callbacks address only the mounted slice. Alignment is checked
// against that slice before any read-modify-write reaches FSKit.
import Foundation
import FSKit
import DiskJockeyLibrary

/// The synchronous FSKit contract, including its actual transfer counts.
/// Tests supply a device here; production uses FSBlockDeviceResource itself.
protocol XfsBlockDeviceIO: AnyObject {
    var blockSize: UInt64 { get }
    var physicalBlockSize: UInt64 { get }
    var blockCount: UInt64 { get }
    var isWritable: Bool { get }
    func read(into buffer: UnsafeMutableRawBufferPointer,
              startingAt offset: off_t, length: Int) throws -> Int
    func write(from buffer: UnsafeRawBufferPointer,
               startingAt offset: off_t, length: Int) throws -> Int
    func flushMetadata() throws
}

extension FSBlockDeviceResource: XfsBlockDeviceIO {
    func flushMetadata() throws { try metadataFlush() }
}

final class XfsBlockDeviceContext {
    // Bound scratch allocations even if the driver requests a huge transfer.
    private static let transferLimit = 1024 * 1024
    private let device: any XfsBlockDeviceIO
    private let sliceStart: UInt64
    private let sliceEnd: UInt64
    private let alignment: Int
    private let lock = NSLock()
    private let cache: BlockReadCache?
    private let stats: IOStatsCollector?
    private let logger: TaggedLogger?
    let sizeBytes: UInt64
    var isWritable: Bool { device.isWritable }

    init(device: any XfsBlockDeviceIO,
         partitionOffset: UInt64? = nil, partitionLength: UInt64? = nil,
         cache: BlockReadCache? = nil, stats: IOStatsCollector? = nil,
         logger: TaggedLogger? = nil) throws {
        let logical = device.blockSize
        let physical = max(logical, device.physicalBlockSize)
        guard logical >= 512, logical.nonzeroBitCount == 1,
              physical.nonzeroBitCount == 1,
              physical <= UInt64(Self.transferLimit) else { throw POSIXError(.EINVAL) }
        let (deviceSize, overflow) = device.blockCount.multipliedReportingOverflow(by: logical)
        guard !overflow, deviceSize <= UInt64(Int64.max) else { throw POSIXError(.EOVERFLOW) }
        let start = partitionOffset ?? 0
        guard start < deviceSize else { throw POSIXError(.EINVAL) }
        let length = partitionLength ?? (deviceSize - start)
        let (end, endOverflow) = start.addingReportingOverflow(length)
        guard !endOverflow else { throw POSIXError(.EOVERFLOW) }
        guard length > 0, end <= deviceSize else { throw POSIXError(.EINVAL) }
        self.device = device
        self.sliceStart = start
        self.sliceEnd = end
        self.sizeBytes = length
        self.alignment = Int(physical)
        self.cache = cache
        self.stats = stats
        self.logger = logger
    }

    /// A malformed slicing option must not silently turn into a whole disk.
    static func partitionOptions(_ argv: [String]) throws -> (offset: UInt64?, length: UInt64?) {
        var offset: UInt64?
        var length: UInt64?
        for raw in argv {
            for pair in raw.split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard kv[0] == "partition_offset" || kv[0] == "partition_length" else { continue }
                guard kv.count == 2, let value = UInt64(kv[1]) else { throw POSIXError(.EINVAL) }
                if kv[0] == "partition_offset" { offset = value } else { length = value }
            }
        }
        return (offset, length)
    }

    // These are the actual fs_core C callbacks, also called directly by tests.
    static let readCallback: @convention(c) (UnsafeMutableRawPointer?, UInt64, UnsafeMutablePointer<UInt8>?, Int) -> Int32 = {
        ctx, offset, buffer, length in
        guard let ctx else { return EIO }
        return Unmanaged<XfsBlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
            .read(into: buffer, offset: offset, length: length)
    }
    static let writeCallback: @convention(c) (UnsafeMutableRawPointer?, UInt64, UnsafePointer<UInt8>?, Int) -> Int32 = {
        ctx, offset, buffer, length in
        guard let ctx else { return EIO }
        return Unmanaged<XfsBlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue()
            .write(from: buffer, offset: offset, length: length)
    }
    static let flushCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { ctx in
        guard let ctx else { return EIO }
        return Unmanaged<XfsBlockDeviceContext>.fromOpaque(ctx).takeUnretainedValue().flush()
    }

    /// Validate both the caller's range and its expanded device transfer.
    private func window(offset: UInt64, length: Int) throws -> (start: UInt64, end: UInt64, alignedStart: UInt64, alignedEnd: UInt64) {
        guard length >= 0 else { throw POSIXError(.EINVAL) }
        let (relativeEnd, overflow) = offset.addingReportingOverflow(UInt64(length))
        guard !overflow, offset <= UInt64(Int64.max), relativeEnd <= UInt64(Int64.max) else {
            throw POSIXError(.EOVERFLOW)
        }
        guard relativeEnd <= sizeBytes else { throw POSIXError(.EINVAL) }
        // Construction and the relative bound prove these additions fit off_t.
        let start = sliceStart + offset
        let end = sliceStart + relativeEnd
        if length == 0 { return (start, end, start, end) }
        let bs = UInt64(alignment)
        let alignedStart = start - start % bs
        let remainder = end % bs
        let (alignedEnd, roundOverflow) = end.addingReportingOverflow(remainder == 0 ? 0 : bs - remainder)
        guard !roundOverflow, alignedEnd <= UInt64(Int64.max) else { throw POSIXError(.EOVERFLOW) }
        // RMW must not touch a neighbouring partition, even to preserve bytes.
        guard alignedStart >= sliceStart, alignedEnd <= sliceEnd else { throw POSIXError(.EINVAL) }
        return (start, end, alignedStart, alignedEnd)
    }

    func read(into buffer: UnsafeMutablePointer<UInt8>?, offset: UInt64, length: Int) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let t0 = monotonicNanos()
        do {
            let w = try window(offset: offset, length: length)
            if length == 0 { return 0 }
            guard let buffer else { throw POSIXError(.EFAULT) }
            let capacity = min(Int(w.alignedEnd - w.alignedStart), Self.transferLimit)
            let tmp = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: alignment)
            defer { tmp.deallocate() }
            var current = w.alignedStart
            while current < w.alignedEnd {
                let count = min(Int(w.alignedEnd - current), capacity)
                if let bytes = cache?.lookup(offset: Int(current), length: count) {
                    _ = bytes.withUnsafeBytes { memcpy(tmp, $0.baseAddress!, count) }
                } else {
                    let ioStart = monotonicNanos()
                    let n = try device.read(into: UnsafeMutableRawBufferPointer(start: tmp, count: count),
                                            startingAt: off_t(current), length: count)
                    guard n == count else { throw POSIXError(.EIO) }
                    cache?.insert(offset: Int(current), length: count,
                                  bytes: Array(UnsafeBufferPointer(start: tmp.assumingMemoryBound(to: UInt8.self), count: count)))
                    stats?.recordBdevRead(bytes: count, latencyNs: monotonicNanos() &- ioStart, error: false)
                }
                let lo = max(current, w.start)
                let hi = min(current + UInt64(count), w.end)
                memcpy(buffer.advanced(by: Int(lo - w.start)), tmp.advanced(by: Int(lo - current)), Int(hi - lo))
                current += UInt64(count)
            }
            return 0
        } catch {
            stats?.recordBdevRead(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
            return report(error, operation: "read")
        }
    }

    func write(from buffer: UnsafePointer<UInt8>?, offset: UInt64, length: Int) -> Int32 {
        // Serialize RMW and flush, so overlapping partial writes cannot lose data.
        lock.lock()
        defer { lock.unlock() }
        let t0 = monotonicNanos()
        do {
            guard device.isWritable else { throw POSIXError(.EROFS) }
            let w = try window(offset: offset, length: length)
            if length == 0 { return 0 }
            guard let buffer else { throw POSIXError(.EFAULT) }
            let capacity = min(Int(w.alignedEnd - w.alignedStart), Self.transferLimit)
            let tmp = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: alignment)
            defer { tmp.deallocate() }
            // A failed/short write may still change bytes. Invalidate first.
            cache?.invalidate(rangeOffset: Int(w.alignedStart), length: Int(w.alignedEnd - w.alignedStart))
            var current = w.alignedStart
            while current < w.alignedEnd {
                let count = min(Int(w.alignedEnd - current), capacity)
                let lo = max(current, w.start)
                let hi = min(current + UInt64(count), w.end)
                let ioStart = monotonicNanos()
                if lo != current || hi != current + UInt64(count) {
                    let n = try device.read(into: UnsafeMutableRawBufferPointer(start: tmp, count: count),
                                            startingAt: off_t(current), length: count)
                    // Never zero-fill an incomplete preservation read.
                    guard n == count else { throw POSIXError(.EIO) }
                }
                memcpy(tmp.advanced(by: Int(lo - current)), buffer.advanced(by: Int(lo - w.start)), Int(hi - lo))
                let n = try device.write(from: UnsafeRawBufferPointer(start: tmp, count: count),
                                         startingAt: off_t(current), length: count)
                guard n == count else { throw POSIXError(.EIO) }
                stats?.recordBdevWrite(bytes: count, latencyNs: monotonicNanos() &- ioStart, error: false)
                current += UInt64(count)
            }
            return 0
        } catch {
            stats?.recordBdevWrite(bytes: 0, latencyNs: monotonicNanos() &- t0, error: true)
            return report(error, operation: "write")
        }
    }

    func flush() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        do {
            try device.flushMetadata()
            return 0
        } catch { return report(error, operation: "flush") }
    }

    private func report(_ error: Error, operation: String) -> Int32 {
        logger?.error("bdev \(operation) error: \(error.localizedDescription)", scope: AppLogScope.io)
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, let code = Int32(exactly: nsError.code), code > 0 { return code }
        return EIO
    }
}
