// The native fs_core handle uses the same callbacks exercised by host-free
// tests. Kept separate so the oracle can link this production wiring too.
import Foundation
import DiskJockeyLibrary

enum XfsBlockDeviceBridge {
    static func makeHandle(contextPtr: UnsafeMutableRawPointer,
                           logger: TaggedLogger? = nil) throws -> OpaquePointer {
        let context = Unmanaged<XfsBlockDeviceContext>.fromOpaque(contextPtr).takeUnretainedValue()
        var coreCfg = FsCoreCallbackCfg()
        coreCfg.read = XfsBlockDeviceContext.readCallback
        coreCfg.write = context.isWritable ? XfsBlockDeviceContext.writeCallback : nil
        coreCfg.flush = XfsBlockDeviceContext.flushCallback
        coreCfg.ctx = contextPtr
        // The context translates partition-relative offsets exactly once and
        // bounds the aligned transfer too.
        coreCfg.size = context.sizeBytes
        guard let handle = withUnsafePointer(to: &coreCfg, { fs_core_device_from_callbacks($0) }) else {
            let error = fs_core_last_error_message().flatMap { String(cString: $0) } ?? "(no error set)"
            logger?.error("fs_core_device_from_callbacks failed: \(error)")
            throw POSIXError(.EIO)
        }
        // Callback devices delegate bounds to the callback. Give native callers
        // an explicit range fence as well, without translating the offset again.
        // The child retains the parent's Arc; the Swift context remains owned
        // by the volume until its driver has unmounted.
        defer { fs_core_device_close(handle) }
        let slice = context.isWritable
            ? fs_core_device_slice_rw(handle, 0, context.sizeBytes)
            : fs_core_device_slice_ro(handle, 0, context.sizeBytes)
        guard let slice else {
            logger?.error("fs_core callback range fence failed")
            throw POSIXError(.EIO)
        }
        return slice
    }
}
