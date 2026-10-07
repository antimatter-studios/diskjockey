// Links the production callbacks and handle builder to the published fs_core
// implementation. POSIX file I/O and Foundation readback are the byte oracle.
import Foundation
import DiskJockeyLibrary

private final class OracleDevice: XfsBlockDeviceIO {
    let blockSize: UInt64 = 512
    let physicalBlockSize: UInt64 = 4096
    let blockCount: UInt64 = 24
    var isWritable = true
    var shortRead = false
    var shortWrite = false
    var flushFails = false
    var writes: [(off_t, Int)] = []
    var flushes = 0
    let fd: Int32
    let url: URL

    init() throws {
        var name = Array((NSTemporaryDirectory() + "xfs-native-oracle-XXXXXX").utf8CString)
        fd = mkstemp(&name)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        url = URL(fileURLWithPath: String(cString: name))
        let sentinel = [UInt8](repeating: 0xAC, count: 12288)
        let n = sentinel.withUnsafeBytes { Darwin.pwrite(fd, $0.baseAddress, $0.count, 0) }
        guard n == sentinel.count else { throw POSIXError(.EIO) }
    }
    deinit { Darwin.close(fd); Darwin.unlink(url.path) }
    func read(into buffer: UnsafeMutableRawBufferPointer, startingAt offset: off_t, length: Int) throws -> Int {
        let n = Darwin.pread(fd, buffer.baseAddress, shortRead ? length - 1 : length, offset)
        guard n >= 0 else { throw POSIXError(.EIO) }
        return n
    }
    func write(from buffer: UnsafeRawBufferPointer, startingAt offset: off_t, length: Int) throws -> Int {
        writes.append((offset, length))
        let n = Darwin.pwrite(fd, buffer.baseAddress, shortWrite ? 1 : length, offset)
        guard n >= 0 else { throw POSIXError(.EIO) }
        return n
    }
    func flushMetadata() throws {
        flushes += 1
        if flushFails { throw POSIXError(.EIO) }
        guard Darwin.fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }
}

@main
struct XfsNativeOracle {
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "XfsNativeOracle", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() throws {
        let device = try OracleDevice()
        let context = try XfsBlockDeviceContext(device: device, partitionOffset: 4096, partitionLength: 4096)
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        let handle = try XfsBlockDeviceBridge.makeHandle(contextPtr: pointer)
        defer { fs_core_device_close(handle) }
        try require(fs_core_device_size_bytes(handle) == 4096, "native device must expose slice size")
        let payload: [UInt8] = [0x77, 0x88]
        let writeResult = payload.withUnsafeBufferPointer {
            fs_core_device_write_at(handle, 1, $0.baseAddress, $0.count)
        }
        try require(writeResult == FS_CORE_OK, "native write must succeed")
        try require(fs_core_device_flush(handle) == FS_CORE_OK && device.flushes == 1, "native flush must reach device")
        var readback = [UInt8](repeating: 0, count: 2)
        let readResult = readback.withUnsafeMutableBufferPointer {
            fs_core_device_read_at(handle, 1, $0.baseAddress, $0.count)
        }
        try require(readResult == FS_CORE_OK && readback == payload, "native read uses same partition offset")
        var expected = [UInt8](repeating: 0xAC, count: 12288)
        expected.replaceSubrange(4097..<4099, with: payload)
        try require(Array(try Data(contentsOf: device.url)) == expected, "POSIX oracle: only requested slice bytes change")
        try require(device.writes.allSatisfy { $0.0 == 4096 && $0.1 == 4096 }, "physical writes stay inside slice")
        print("ok: native callbacks, partition offsets, aligned RMW, flush and independent byte readback")

        let before = device.writes.count
        for offset: UInt64 in [4095, 4096, UInt64.max] {
            let code = payload.withUnsafeBufferPointer {
                fs_core_device_write_at(handle, offset, $0.baseAddress, $0.count)
            }
            try require(code == FS_CORE_OUT_OF_BOUNDS, "native bounds must reject offset \(offset)")
        }
        try require(device.writes.count == before, "out-of-slice requests must not reach physical device")
        device.shortRead = true
        let preservation = payload.withUnsafeBufferPointer { fs_core_device_write_at(handle, 1, $0.baseAddress, $0.count) }
        try require(preservation == FS_CORE_IO && device.writes.count == before, "short RMW read must prevent write")
        device.shortRead = false
        device.shortWrite = true
        let short = payload.withUnsafeBufferPointer { fs_core_device_write_at(handle, 1, $0.baseAddress, $0.count) }
        try require(short == FS_CORE_IO, "short native write must fail")
        device.flushFails = true
        try require(fs_core_device_flush(handle) == FS_CORE_IO, "native flush error must propagate")
        device.isWritable = false
        let roHandle = try XfsBlockDeviceBridge.makeHandle(contextPtr: pointer)
        defer { fs_core_device_close(roHandle) }
        let readOnly = payload.withUnsafeBufferPointer { fs_core_device_write_at(roHandle, 0, $0.baseAddress, $0.count) }
        try require(readOnly == FS_CORE_READ_ONLY, "read-only resource must expose no native writer")
        try require(device.writes.allSatisfy { $0.0 >= 4096 && $0.0 + off_t($0.1) <= 8192 }, "no physical write escapes mounted slice")
        print("ok: native slice/overflow refusal, short read/write failures, read-only capability and flush errors")
        withExtendedLifetime(context) {}
    }
}
