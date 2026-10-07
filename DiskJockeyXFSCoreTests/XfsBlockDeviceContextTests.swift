import Foundation
import Testing
import DiskJockeyLibrary
@testable import DiskJockeyXFSCore

/// A real file is the test device. POSIX pread/pwrite/fsync and a separate
/// Foundation readback provide the byte oracle, independently of the bridge.
private final class TestBlockDevice: XfsBlockDeviceIO {
    var blockSize: UInt64 = 512
    var physicalBlockSize: UInt64 = 512
    var blockCount: UInt64
    var isWritable = true
    var readLimit: Int?
    var writeLimit: Int?
    var readError: Error?
    var writeError: Error?
    var flushError: Error?
    var reads: [(off_t, Int)] = []
    var writes: [(off_t, Int)] = []
    var flushes = 0
    private let fd: Int32
    let url: URL
    let original: [UInt8]

    init(size: Int = 16384) throws {
        blockCount = UInt64(size / 512)
        original = (0..<size).map { UInt8($0 % 251) }
        var name = Array((NSTemporaryDirectory() + "xfs-bridge-XXXXXX").utf8CString)
        fd = mkstemp(&name)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        url = URL(fileURLWithPath: String(cString: name))
        let count = original.withUnsafeBytes { Darwin.pwrite(fd, $0.baseAddress, $0.count, 0) }
        guard count == size else { throw POSIXError(.EIO) }
    }

    deinit {
        Darwin.close(fd)
        Darwin.unlink(url.path)
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, startingAt offset: off_t, length: Int) throws -> Int {
        reads.append((offset, length))
        if let readError { throw readError }
        let n = Darwin.pread(fd, buffer.baseAddress, min(length, readLimit ?? length), offset)
        guard n >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return n
    }

    func write(from buffer: UnsafeRawBufferPointer, startingAt offset: off_t, length: Int) throws -> Int {
        writes.append((offset, length))
        if let writeError { throw writeError }
        let n = Darwin.pwrite(fd, buffer.baseAddress, min(length, writeLimit ?? length), offset)
        guard n >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return n
    }

    func flushMetadata() throws {
        flushes += 1
        if let flushError { throw flushError }
        guard Darwin.fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }

    func bytes() throws -> [UInt8] { Array(try Data(contentsOf: url)) }
}

private func contextPointer(_ context: XfsBlockDeviceContext) -> UnsafeMutableRawPointer {
    Unmanaged.passUnretained(context).toOpaque()
}

private func write(_ context: XfsBlockDeviceContext, offset: UInt64, bytes: [UInt8]) -> Int32 {
    bytes.withUnsafeBufferPointer {
        XfsBlockDeviceContext.writeCallback(contextPointer(context), offset, $0.baseAddress, $0.count)
    }
}

private func read(_ context: XfsBlockDeviceContext, offset: UInt64, count: Int) -> (Int32, [UInt8]) {
    var bytes = [UInt8](repeating: 0, count: count)
    let code = bytes.withUnsafeMutableBufferPointer {
        XfsBlockDeviceContext.readCallback(contextPointer(context), offset, $0.baseAddress, $0.count)
    }
    return (code, bytes)
}

@Suite("XFS bounded block callbacks")
struct XfsBlockDeviceContextTests {
    @Test(arguments: [512, 4096])
    func alignedWriteUsesDeviceAlignment(blockSize: Int) throws {
        let device = try TestBlockDevice()
        device.physicalBlockSize = UInt64(blockSize)
        let context = try XfsBlockDeviceContext(device: device)
        let payload = [UInt8](repeating: 0xA5, count: blockSize)
        #expect(write(context, offset: UInt64(blockSize), bytes: payload) == 0)
        #expect(device.reads.isEmpty)
        #expect(device.writes.count == 1)
        #expect(device.writes[0].0 == off_t(blockSize))
        #expect(device.writes[0].1 == blockSize)
        var expected = device.original
        expected.replaceSubrange(blockSize..<(2 * blockSize), with: payload)
        #expect(try device.bytes() == expected)
    }

    @Test(arguments: [512, 4096])
    func partialWritePreservesHeadAndTail(blockSize: Int) throws {
        let device = try TestBlockDevice()
        device.physicalBlockSize = UInt64(blockSize)
        let context = try XfsBlockDeviceContext(device: device, partitionOffset: 4096, partitionLength: 8192)
        let payload = [UInt8](repeating: 0xEE, count: blockSize + 7)
        #expect(write(context, offset: 13, bytes: payload) == 0)
        #expect(device.reads.count == 1)
        #expect(device.writes[0].0 == 4096)
        #expect(device.writes[0].1 == 2 * blockSize)
        var expected = device.original
        expected.replaceSubrange(4109..<(4109 + payload.count), with: payload)
        #expect(try device.bytes() == expected)
    }

    @Test func sliceOracleRejectsEveryEscapingWrite() throws {
        let device = try TestBlockDevice()
        device.physicalBlockSize = 4096
        let context = try XfsBlockDeviceContext(device: device, partitionOffset: 4096, partitionLength: 4096)
        // Exhaust the slice edges, including ranges that start inside but end outside.
        for offset: UInt64 in [0, 1, 4095, 4096, 4097, UInt64.max] {
            for length in [1, 512, 4096, 4097] {
                let before = device.writes.count
                let code = write(context, offset: offset, bytes: [UInt8](repeating: 0xCD, count: length))
                if offset <= 4096, UInt64(length) <= 4096 - offset { #expect(code == 0) }
                else { #expect(code != 0); #expect(device.writes.count == before) }
            }
        }
        #expect(XfsBlockDeviceContext.flushCallback(contextPointer(context)) == 0)
        #expect(device.flushes == 1)
        #expect(device.writes.allSatisfy { $0.0 >= 4096 && $0.0 + off_t($0.1) <= 8192 })
        #expect(device.writes.allSatisfy { $0.0 % 4096 == 0 && $0.1 % 4096 == 0 })
        let bytes = try device.bytes()
        #expect(Array(bytes[..<4096]) == Array(device.original[..<4096]))
        #expect(Array(bytes[8192...]) == Array(device.original[8192...]))
    }

    @Test func physicalExpansionCannotEscapeMisalignedSlice() throws {
        let device = try TestBlockDevice()
        device.physicalBlockSize = 4096
        let context = try XfsBlockDeviceContext(device: device, partitionOffset: 512, partitionLength: 8192)
        #expect(write(context, offset: 0, bytes: [1]) == EINVAL)
        #expect(write(context, offset: 8191, bytes: [1]) == EINVAL)
        #expect(device.reads.isEmpty && device.writes.isEmpty)
        #expect(write(context, offset: 3584, bytes: [UInt8](repeating: 1, count: 4096)) == 0)
        #expect(device.writes[0].0 == 4096 && device.writes[0].1 == 4096)
    }

    @Test(arguments: [0, 511])
    func shortWriteIsFailure(shortCount: Int) throws {
        let device = try TestBlockDevice()
        device.writeLimit = shortCount
        let context = try XfsBlockDeviceContext(device: device, partitionOffset: 4096, partitionLength: 4096)
        #expect(write(context, offset: 0, bytes: [UInt8](repeating: 7, count: 512)) == EIO)
        #expect(device.writes.count == 1)
        let bytes = try device.bytes()
        #expect(Array(bytes[..<4096]) == Array(device.original[..<4096]))
        #expect(Array(bytes[8192...]) == Array(device.original[8192...]))
    }

    @Test func incompletePreservationReadNeverWritesZeroes() throws {
        let device = try TestBlockDevice()
        device.readLimit = 511
        let context = try XfsBlockDeviceContext(device: device)
        #expect(write(context, offset: 1, bytes: [1]) == EIO)
        #expect(device.writes.isEmpty)
        #expect(try device.bytes() == device.original)
    }

    @Test(arguments: [UInt64.max, UInt64(Int64.max) + 1, UInt64(Int64.max)])
    func overflowRefusedBeforeIO(offset: UInt64) throws {
        let device = try TestBlockDevice()
        let context = try XfsBlockDeviceContext(device: device)
        #expect(write(context, offset: offset, bytes: [1, 2]) == EOVERFLOW)
        #expect(read(context, offset: offset, count: 2).0 == EOVERFLOW)
        #expect(device.reads.isEmpty && device.writes.isEmpty)
    }

    @Test func negativeAndHugeLengthRefusedBeforeBufferAccess() throws {
        let device = try TestBlockDevice()
        let context = try XfsBlockDeviceContext(device: device)
        let pointer = contextPointer(context)
        #expect(XfsBlockDeviceContext.writeCallback(pointer, 0, nil, -1) == EINVAL)
        #expect(XfsBlockDeviceContext.readCallback(pointer, 0, nil, -1) == EINVAL)
        #expect(XfsBlockDeviceContext.writeCallback(pointer, 1, nil, Int.max) == EOVERFLOW)
        #expect(XfsBlockDeviceContext.readCallback(pointer, 1, nil, Int.max) == EOVERFLOW)
        #expect(device.reads.isEmpty && device.writes.isEmpty)
    }

    @Test func zeroLengthAndNullPointers() throws {
        let device = try TestBlockDevice()
        let context = try XfsBlockDeviceContext(device: device)
        let pointer = contextPointer(context)
        #expect(XfsBlockDeviceContext.readCallback(pointer, context.sizeBytes, nil, 0) == 0)
        #expect(XfsBlockDeviceContext.writeCallback(pointer, context.sizeBytes, nil, 0) == 0)
        #expect(XfsBlockDeviceContext.writeCallback(pointer, context.sizeBytes + 1, nil, 0) == EINVAL)
        #expect(XfsBlockDeviceContext.readCallback(pointer, 0, nil, 1) == EFAULT)
        #expect(XfsBlockDeviceContext.writeCallback(pointer, 0, nil, 1) == EFAULT)
        #expect(XfsBlockDeviceContext.readCallback(nil, 0, nil, 0) == EIO)
        #expect(XfsBlockDeviceContext.writeCallback(nil, 0, nil, 0) == EIO)
        #expect(XfsBlockDeviceContext.flushCallback(nil) == EIO)
        #expect(device.reads.isEmpty && device.writes.isEmpty && device.flushes == 0)
    }

    @Test func readOnlyRefusalPrecedesRMW() throws {
        let device = try TestBlockDevice()
        device.isWritable = false
        let context = try XfsBlockDeviceContext(device: device)
        #expect(!context.isWritable)
        #expect(write(context, offset: 1, bytes: [1]) == EROFS)
        #expect(XfsBlockDeviceContext.writeCallback(contextPointer(context), 0, nil, 0) == EROFS)
        #expect(device.reads.isEmpty && device.writes.isEmpty)
        #expect(read(context, offset: 0, count: 512).0 == 0)
    }

    @Test func errorsPropagateForReadWritePreservationAndFlush() throws {
        let device = try TestBlockDevice()
        let context = try XfsBlockDeviceContext(device: device)
        device.readError = POSIXError(.ENXIO)
        #expect(read(context, offset: 0, count: 1).0 == ENXIO)
        #expect(write(context, offset: 1, bytes: [1]) == ENXIO)
        #expect(device.writes.isEmpty)
        device.readError = nil
        device.writeError = POSIXError(.ENOSPC)
        #expect(write(context, offset: 0, bytes: [UInt8](repeating: 1, count: 512)) == ENOSPC)
        device.flushError = POSIXError(.EIO)
        #expect(XfsBlockDeviceContext.flushCallback(contextPointer(context)) == EIO)
        device.flushError = POSIXError(.ENXIO)
        #expect(XfsBlockDeviceContext.flushCallback(contextPointer(context)) == ENXIO)
    }

    @Test func nonPOSIXErrorsBecomeIOErrors() throws {
        let device = try TestBlockDevice()
        let context = try XfsBlockDeviceContext(device: device)
        let error = NSError(domain: "test.device", code: 123)
        device.readError = error
        device.writeError = error
        device.flushError = error
        #expect(read(context, offset: 0, count: 512).0 == EIO)
        #expect(write(context, offset: 0, bytes: [UInt8](repeating: 1, count: 512)) == EIO)
        #expect(XfsBlockDeviceContext.flushCallback(contextPointer(context)) == EIO)
    }

    @Test func readsAreSliceRelativeAndRejectShortTransfers() throws {
        let device = try TestBlockDevice()
        let context = try XfsBlockDeviceContext(device: device, partitionOffset: 4096, partitionLength: 4096)
        let result = read(context, offset: 3, count: 513)
        #expect(result.0 == 0)
        #expect(result.1 == Array(device.original[4099..<4612]))
        #expect(device.reads[0].0 == 4096 && device.reads[0].1 == 1024)
        device.readLimit = 511
        #expect(read(context, offset: 0, count: 512).0 == EIO)
        #expect(read(context, offset: 4096, count: 1).0 == EINVAL)
    }

    @Test func successfulAndShortWritesInvalidateCachedReads() throws {
        let device = try TestBlockDevice()
        let cache = BlockReadCache(maxEntries: 4)
        let context = try XfsBlockDeviceContext(device: device, cache: cache)
        #expect(read(context, offset: 0, count: 512).0 == 0)
        #expect(read(context, offset: 0, count: 512).0 == 0)
        #expect(device.reads.count == 1)
        #expect(write(context, offset: 0, bytes: [UInt8](repeating: 9, count: 512)) == 0)
        #expect(read(context, offset: 0, count: 512).1 == [UInt8](repeating: 9, count: 512))
        device.writeLimit = 1
        #expect(write(context, offset: 0, bytes: [UInt8](repeating: 8, count: 512)) == EIO)
        let result = read(context, offset: 0, count: 512)
        #expect(result.0 == 0 && result.1[0] == 8 && result.1[1] == 9)
    }

    @Test func largeTransfersUseBoundedAlignedChunks() throws {
        let device = try TestBlockDevice(size: 3 * 1024 * 1024)
        device.physicalBlockSize = 4096
        let context = try XfsBlockDeviceContext(device: device)
        let payload = [UInt8](repeating: 0xBB, count: 2 * 1024 * 1024 + 7)
        #expect(write(context, offset: 13, bytes: payload) == 0)
        #expect(device.writes.count == 3)
        #expect(device.writes.allSatisfy { $0.1 <= 1024 * 1024 && $0.1 % 4096 == 0 })
        #expect(read(context, offset: 13, count: payload.count).1 == payload)
        var expected = device.original
        expected.replaceSubrange(13..<(13 + payload.count), with: payload)
        #expect(try device.bytes() == expected)
    }

    @Test func capacityAndSliceOverflowAreRejected() throws {
        let device = try TestBlockDevice()
        device.blockCount = UInt64.max
        #expect(throws: POSIXError(.EOVERFLOW)) { try XfsBlockDeviceContext(device: device) }
        device.blockCount = UInt64(Int64.max) / 512 + 1
        #expect(throws: POSIXError(.EOVERFLOW)) { try XfsBlockDeviceContext(device: device) }
        device.blockCount = 32
        #expect(throws: POSIXError(.EOVERFLOW)) {
            try XfsBlockDeviceContext(device: device, partitionOffset: 512, partitionLength: UInt64.max)
        }
    }

    @Test(arguments: [UInt64(0), 1, 511, 513, 2 * 1024 * 1024])
    func invalidGeometryRejected(blockSize: UInt64) throws {
        let device = try TestBlockDevice()
        device.blockSize = blockSize
        #expect(throws: POSIXError(.EINVAL)) { try XfsBlockDeviceContext(device: device) }
    }

    @Test func invalidPhysicalSizeAndEmptyDeviceRejected() throws {
        let device = try TestBlockDevice()
        device.physicalBlockSize = 4097
        #expect(throws: POSIXError(.EINVAL)) { try XfsBlockDeviceContext(device: device) }
        device.physicalBlockSize = 0
        #expect(try XfsBlockDeviceContext(device: device).sizeBytes == 16384)
        device.blockCount = 0
        #expect(throws: POSIXError(.EINVAL)) { try XfsBlockDeviceContext(device: device) }
    }

    @Test func invalidSliceRejectedAndOptionalBoundsDefaultSafely() throws {
        let device = try TestBlockDevice()
        #expect(throws: POSIXError(.EINVAL)) { try XfsBlockDeviceContext(device: device, partitionOffset: 16384) }
        #expect(throws: POSIXError(.EINVAL)) { try XfsBlockDeviceContext(device: device, partitionOffset: 16385) }
        #expect(throws: POSIXError(.EINVAL)) { try XfsBlockDeviceContext(device: device, partitionLength: 0) }
        #expect(throws: POSIXError(.EINVAL)) { try XfsBlockDeviceContext(device: device, partitionOffset: 4096, partitionLength: 16384) }
        #expect(try XfsBlockDeviceContext(device: device, partitionOffset: 4096).sizeBytes == 12288)
        #expect(try XfsBlockDeviceContext(device: device, partitionLength: 4096).sizeBytes == 4096)
    }

    @Test func partitionOptionsAreParsedIndependently() throws {
        let both = try XfsBlockDeviceContext.partitionOptions(["other=1,partition_offset=4096,partition_length=8192"])
        #expect(both.offset == 4096 && both.length == 8192)
        let offset = try XfsBlockDeviceContext.partitionOptions(["partition_offset=512"])
        #expect(offset.offset == 512 && offset.length == nil)
        let none = try XfsBlockDeviceContext.partitionOptions(["ro", ",,"])
        #expect(none.offset == nil && none.length == nil)
    }

    @Test(arguments: ["partition_offset=-1", "partition_offset=", "partition_offset", "partition_length=garbage", "partition_length=18446744073709551616"])
    func malformedPartitionOptionsFail(option: String) {
        #expect(throws: POSIXError(.EINVAL)) { try XfsBlockDeviceContext.partitionOptions([option]) }
    }
}
