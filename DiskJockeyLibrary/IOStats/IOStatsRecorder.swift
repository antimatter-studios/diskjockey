/*
 * IOStatsRecorder.swift — single source of truth for the per-mount I/O
 * counter aggregator used by every extension target. Lives in the
 * shared `DiskJockeyLibrary` framework; consumed by DiskJockeyEXT4,
 * DiskJockeyNTFS, and DiskJockeyFileProvider via `import DiskJockeyLibrary`.
 *
 * Replaces three near-identical per-extension copies that previously
 * lived alongside each extension's own `AppLog.swift`. AppLog stays
 * per-extension (each subsystem has its own NDJSON sink path); the
 * counter aggregation is purely mechanical and benefits from the dedup.
 *
 * What's generic vs. specialised:
 *   • The struct + class are entirely protocol-agnostic. They know
 *     about "logical" vs "block-device" counters and a 1 Hz emit
 *     cadence; nothing else.
 *   • Each call site supplies an `emit` closure that wraps its own
 *     TaggedLogger so AppLog stays per-extension as before.
 *   • FileProvider also supplies a `preflush` closure that overlays
 *     Go-side transport counters from networkfs_get_stats() onto the
 *     Swift-counted snapshot before emission. EXT4/NTFS pass nil.
 *
 * MIT License — see LICENSE
 */

import Foundation
import os

/// Mutable counters held under the recorder's unfair lock. Snapshotted
/// at flush time and shipped over NDJSON. The bdev_* fields stay zero
/// for FileProvider (no underlying block device) — kept in the struct
/// so the wire format matches the FSKit emitters and the host-side
/// decoder is one path.
public struct IOStatsCounters: Equatable, Sendable {
    public var bytesRead: UInt64 = 0
    public var bytesWritten: UInt64 = 0
    public var opsRead: UInt64 = 0
    public var opsWritten: UInt64 = 0
    public var errorsRead: UInt64 = 0
    public var errorsWritten: UInt64 = 0
    public var readLatencyNs: UInt64 = 0
    public var writeLatencyNs: UInt64 = 0

    public var bdevBytesRead: UInt64 = 0
    public var bdevBytesWritten: UInt64 = 0
    public var bdevOpsRead: UInt64 = 0
    public var bdevOpsWritten: UInt64 = 0
    public var bdevReadLatencyNs: UInt64 = 0
    public var bdevWriteLatencyNs: UInt64 = 0
    public var bdevErrorsRead: UInt64 = 0
    public var bdevErrorsWritten: UInt64 = 0

    public init() {}

    /// Render the counters as the wire-format dict the host-side
    /// `IOCounters(fields:)` decoder expects. Centralising the field
    /// names here means a new field is added in exactly one place
    /// across the producer side.
    public func asFields() -> [String: String] {
        return [
            "bytes_read": "\(bytesRead)",
            "bytes_written": "\(bytesWritten)",
            "ops_read": "\(opsRead)",
            "ops_written": "\(opsWritten)",
            "errors_read": "\(errorsRead)",
            "errors_written": "\(errorsWritten)",
            "read_latency_ns": "\(readLatencyNs)",
            "write_latency_ns": "\(writeLatencyNs)",
            "bdev_bytes_read": "\(bdevBytesRead)",
            "bdev_bytes_written": "\(bdevBytesWritten)",
            "bdev_ops_read": "\(bdevOpsRead)",
            "bdev_ops_written": "\(bdevOpsWritten)",
            "bdev_read_latency_ns": "\(bdevReadLatencyNs)",
            "bdev_write_latency_ns": "\(bdevWriteLatencyNs)",
            "bdev_errors_read": "\(bdevErrorsRead)",
            "bdev_errors_written": "\(bdevErrorsWritten)",
        ]
    }
}

/// Per-mount counter aggregator. One instance lives for the lifetime
/// of a mount; recorders on the hot path call into it lock-free-ish
/// (single unfair lock acquisition per op, ns-scale).
public final class IOStatsRecorder: @unchecked Sendable {
    /// Closure each call site provides to push a finished snapshot
    /// over NDJSON. The recorder doesn't import any logger type —
    /// keeping AppLog per-extension is intentional (different
    /// subsystems, different sinks).
    public typealias Emitter = (_ fields: [String: String]) -> Void

    /// Optional pre-flush hook that runs on every tick (just before
    /// the duplicate-snapshot suppression check). Used by FileProvider
    /// to overlay authoritative byte/op counters pulled from the Go
    /// side; FSKit recorders pass nil.
    public typealias PreflushHook = (_ counters: inout IOStatsCounters) -> Void

    private let counters = OSAllocatedUnfairLock(initialState: IOStatsCounters())
    private let queue: DispatchQueue
    private let emit: Emitter
    private let preflush: PreflushHook?
    private var timer: DispatchSourceTimer?
    private var lastEmitted: IOStatsCounters? = nil

    /// - Parameters:
    ///   - label: short identifier for the recorder's dispatch queue
    ///     (BSD name for FSKit, mount UUID for FileProvider).
    ///   - emit: called on each flush with the wire-format dict.
    ///   - preflush: optional hook to mutate counters before the
    ///     duplicate-snapshot check (used by FileProvider for the
    ///     Go-overlay).
    public init(label: String,
                emit: @escaping Emitter,
                preflush: PreflushHook? = nil) {
        self.queue = DispatchQueue(
            label: "com.antimatterstudios.diskjockey.iostats.\(label)")
        self.emit = emit
        self.preflush = preflush
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        // 1 Hz — fast enough that a sparkline animates smoothly in
        // the detail view, slow enough that the NDJSON sink isn't
        // flooded when a volume is busy. Idle volumes self-suppress
        // (see flush).
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        self.timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        flush(force: true)
    }

    // MARK: - Hot-path recorders (logical / file-level)

    public func recordRead(bytes: Int, latencyNs: UInt64, error: Bool) {
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

    public func recordWrite(bytes: Int, latencyNs: UInt64, error: Bool) {
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
    //
    // FileProvider call sites never touch these — the bdev counters
    // stay zero in its emitted events, which the host-side display
    // already handles via `showPhysical: false`.

    public func recordBdevRead(bytes: Int, latencyNs: UInt64, error: Bool) {
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

    public func recordBdevWrite(bytes: Int, latencyNs: UInt64, error: Bool) {
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

    /// Snapshot counters, run any pre-flush hook, suppress emit if
    /// nothing changed since last tick, otherwise hand the wire-format
    /// dict to the caller-provided emitter. On stop we force a final
    /// flush so the host sees the closing tally.
    private func flush(force: Bool = false) {
        var snapshot = counters.withLock { $0 }
        if let preflush = self.preflush {
            preflush(&snapshot)
            // Persist the overlaid values so subsequent
            // hot-path increments build on the authoritative numbers
            // rather than re-overlaying the deltas every tick.
            counters.withLock { $0 = snapshot }
        }
        if !force, let last = lastEmitted, last == snapshot { return }
        lastEmitted = snapshot
        emit(snapshot.asFields())
    }
}

/// Back-compat alias — the type used to be called `IOStatsCollector`
/// in each per-extension copy. New code should reach for
/// `IOStatsRecorder` directly.
public typealias IOStatsCollector = IOStatsRecorder

/// Helper: monotonic nanoseconds since boot. Used to bracket a hot-path
/// operation so we can record its latency.
@inlinable
public func monotonicNanos() -> UInt64 {
    return DispatchTime.now().uptimeNanoseconds
}
