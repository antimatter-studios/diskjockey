/*
 * IOStatsCollector.swift — runtime I/O metrics for a FileProvider mount.
 *
 * Hooked into `fetchContents` (the only data-bearing op in the read-only
 * MVP). Counters tick under an unfair lock; a 1 Hz timer flushes a
 * snapshot as a structured `io.stats` event over the existing NDJSON IPC,
 * where the host app's DirectMountRegistry ingests it and derives
 * throughput.
 *
 * Mirror of DiskJockeyEXT4/IOStatsCollector.swift — kept duplicated
 * (rather than shared via a framework) to match the existing pattern
 * for AppLog.swift, which is also per-extension. Block-device metrics
 * are absent here because the FileProvider talks to a remote network FS,
 * not a local block device — only the logical / "file"-level half of
 * the counter set is populated.
 *
 * MIT License — see LICENSE
 */

import Foundation
import os

/// Mutable counters held under the collector's unfair lock. Snapshotted
/// at flush time and shipped over NDJSON. The bdev_* counters always
/// stay zero for FileProvider — kept in the struct so the wire format
/// matches the FSKit emitters and the host-side decoder is one path.
struct IOCounters: Equatable {
    var bytesRead: UInt64 = 0
    var bytesWritten: UInt64 = 0
    var opsRead: UInt64 = 0
    var opsWritten: UInt64 = 0
    var errorsRead: UInt64 = 0
    var errorsWritten: UInt64 = 0
    var readLatencyNs: UInt64 = 0
    var writeLatencyNs: UInt64 = 0

    var bdevBytesRead: UInt64 = 0
    var bdevBytesWritten: UInt64 = 0
    var bdevOpsRead: UInt64 = 0
    var bdevOpsWritten: UInt64 = 0
    var bdevReadLatencyNs: UInt64 = 0
    var bdevWriteLatencyNs: UInt64 = 0
    var bdevErrorsRead: UInt64 = 0
    var bdevErrorsWritten: UInt64 = 0
}

/// Per-mount counter aggregator. One instance lives for the lifetime
/// of a FileProvider extension instance. Note that `fileproviderd`
/// freely respawns extensions — counters reset to 0 on respawn rather
/// than persisting. Good enough for live activity display; if we ever
/// want lifetime totals we'd persist to the App Group plist.
final class IOStatsCollector: @unchecked Sendable {
    private let counters = OSAllocatedUnfairLock(initialState: IOCounters())
    /// Subject-tagged logger — already carries `fields["mount"]=<id>`,
    /// so the collector doesn't add a routing key itself.
    private let log: TaggedLogger
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var lastEmitted: IOCounters? = nil

    init(label: String, log: TaggedLogger) {
        self.log = log
        self.queue = DispatchQueue(
            label: "com.antimatterstudios.diskjockey.iostats.\(label)")
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        self.timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        flush(force: true)
    }

    // MARK: - Hot-path recorders

    func recordRead(bytes: Int, latencyNs: UInt64, error: Bool) {
        counters.withLock { c in
            if error {
                c.errorsRead &+= 1
            } else {
                c.bytesRead &+= UInt64(max(0, bytes))
                c.opsRead &+= 1
                c.readLatencyNs &+= latencyNs
            }
        }
    }

    func recordWrite(bytes: Int, latencyNs: UInt64, error: Bool) {
        counters.withLock { c in
            if error {
                c.errorsWritten &+= 1
            } else {
                c.bytesWritten &+= UInt64(max(0, bytes))
                c.opsWritten &+= 1
                c.writeLatencyNs &+= latencyNs
            }
        }
    }

    // MARK: - Flush

    private func flush(force: Bool = false) {
        let snapshot = counters.withLock { $0 }
        if !force, let last = lastEmitted, last == snapshot { return }
        lastEmitted = snapshot
        log.event(kind: "io.stats", fields: [
            "bytes_read": "\(snapshot.bytesRead)",
            "bytes_written": "\(snapshot.bytesWritten)",
            "ops_read": "\(snapshot.opsRead)",
            "ops_written": "\(snapshot.opsWritten)",
            "errors_read": "\(snapshot.errorsRead)",
            "errors_written": "\(snapshot.errorsWritten)",
            "read_latency_ns": "\(snapshot.readLatencyNs)",
            "write_latency_ns": "\(snapshot.writeLatencyNs)",
            "bdev_bytes_read": "\(snapshot.bdevBytesRead)",
            "bdev_bytes_written": "\(snapshot.bdevBytesWritten)",
            "bdev_ops_read": "\(snapshot.bdevOpsRead)",
            "bdev_ops_written": "\(snapshot.bdevOpsWritten)",
            "bdev_read_latency_ns": "\(snapshot.bdevReadLatencyNs)",
            "bdev_write_latency_ns": "\(snapshot.bdevWriteLatencyNs)",
            "bdev_errors_read": "\(snapshot.bdevErrorsRead)",
            "bdev_errors_written": "\(snapshot.bdevErrorsWritten)",
        ])
    }
}

@inline(__always)
func monotonicNanos() -> UInt64 {
    return DispatchTime.now().uptimeNanoseconds
}
