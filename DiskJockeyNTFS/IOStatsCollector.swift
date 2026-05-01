/*
 * IOStatsCollector.swift — runtime I/O metrics for a mounted volume.
 *
 * Hooked into the volume's read/write paths (logical, file-level) and
 * the NTFSBlockDeviceContext (physical, device-level). Counters tick
 * on the hot path under an unfair lock; a 1 Hz timer flushes a snapshot
 * as a structured `io.stats` event over the existing NDJSON IPC, where
 * the host app's AttachedDisksModel ingests it and derives throughput.
 *
 * The "logical vs physical" split is the interesting part: a 4-byte
 * stat or a tiny file read pulls an entire block off the device, so
 * physical bytes ≫ logical bytes for metadata-heavy workloads. The
 * detail view shows both so the user can see the FS amplification.
 *
 * Mirror of DiskJockeyEXT4/IOStatsCollector.swift — kept duplicated
 * (rather than shared via a framework) to match the existing pattern
 * for AppLog.swift, which is also per-extension.
 *
 * MIT License — see LICENSE
 */

import Foundation
import os

/// Mutable counters held under the collector's unfair lock. Snapshotted
/// at flush time and shipped over NDJSON.
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

/// Per-volume counter aggregator. One instance lives for the lifetime
/// of a mount; recorders on the hot path call into it lock-free-ish
/// (single unfair lock acquisition per op, ns-scale).
final class IOStatsCollector: @unchecked Sendable {
    private let counters = OSAllocatedUnfairLock(initialState: IOCounters())
    /// Subject-tagged logger — already carries routing fields (e.g.
    /// `fields["bsd"]=<disk>` or `fields["mount"]=<id>`), so the
    /// collector doesn't need to know the routing key. Whatever the
    /// caller wraps stays attached to every emitted `io.stats` line.
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
        // 1 Hz — fast enough that a sparkline animates smoothly in the
        // detail view, slow enough that the NDJSON sink isn't flooded
        // when a volume is busy. Idle volumes self-suppress (see flush).
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

    // MARK: - Hot-path recorders (logical / file-level)

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

    // MARK: - Hot-path recorders (physical / block-device-level)

    func recordBdevRead(bytes: Int, latencyNs: UInt64, error: Bool) {
        counters.withLock { c in
            if error {
                c.bdevErrorsRead &+= 1
            } else {
                c.bdevBytesRead &+= UInt64(max(0, bytes))
                c.bdevOpsRead &+= 1
                c.bdevReadLatencyNs &+= latencyNs
            }
        }
    }

    func recordBdevWrite(bytes: Int, latencyNs: UInt64, error: Bool) {
        counters.withLock { c in
            if error {
                c.bdevErrorsWritten &+= 1
            } else {
                c.bdevBytesWritten &+= UInt64(max(0, bytes))
                c.bdevOpsWritten &+= 1
                c.bdevWriteLatencyNs &+= latencyNs
            }
        }
    }

    // MARK: - Flush

    /// Emit an `io.stats` event with cumulative counters. When `force`
    /// is false (the timer path), suppress emission if nothing changed
    /// since the last flush — keeps the NDJSON quiet on idle volumes.
    /// On stop we force a final flush so the UI sees the closing tally.
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
        ], scope: AppLogScope.stats)
    }
}

/// Helper: monotonic nanoseconds since boot. Used to bracket a hot-path
/// operation so we can record its latency.
@inline(__always)
func monotonicNanos() -> UInt64 {
    return DispatchTime.now().uptimeNanoseconds
}
