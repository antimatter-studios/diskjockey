//
// IOStats.swift — host-side projection of the `io.stats` events emitted
// by FSKit + FileProvider extensions.
//
// Each subject (an attached disk OR a direct-mount domain) gets one
// `IOStats` value: the latest cumulative counters plus a bounded ring
// buffer of per-second throughput samples derived from successive
// counter snapshots. The detail-view sparkline graph reads `samples`
// directly — it's already in "rate per tick" form.
//
// We keep both *logical* (file-level) and *physical* (block-device-level)
// throughput tracks so the detail view can show the FS amplification
// factor for metadata-heavy workloads.
//

import Foundation

/// Mirror of the on-wire counter set the extension emits. Cumulative
/// since the extension instance booted (FSKit volume mount / FileProvider
/// extension respawn). Reset detection lives in `IOStats.absorb`.
public struct IOCounters: Equatable, Hashable, Sendable {
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

    /// Decode from the string-typed dict the extensions emit. Missing
    /// keys default to zero — keeps the wire format forward-compatible
    /// (a future extension can add fields without breaking older hosts).
    public init(fields: [String: String]) {
        self.bytesRead = IOCounters.u64(fields["bytes_read"])
        self.bytesWritten = IOCounters.u64(fields["bytes_written"])
        self.opsRead = IOCounters.u64(fields["ops_read"])
        self.opsWritten = IOCounters.u64(fields["ops_written"])
        self.errorsRead = IOCounters.u64(fields["errors_read"])
        self.errorsWritten = IOCounters.u64(fields["errors_written"])
        self.readLatencyNs = IOCounters.u64(fields["read_latency_ns"])
        self.writeLatencyNs = IOCounters.u64(fields["write_latency_ns"])
        self.bdevBytesRead = IOCounters.u64(fields["bdev_bytes_read"])
        self.bdevBytesWritten = IOCounters.u64(fields["bdev_bytes_written"])
        self.bdevOpsRead = IOCounters.u64(fields["bdev_ops_read"])
        self.bdevOpsWritten = IOCounters.u64(fields["bdev_ops_written"])
        self.bdevReadLatencyNs = IOCounters.u64(fields["bdev_read_latency_ns"])
        self.bdevWriteLatencyNs = IOCounters.u64(fields["bdev_write_latency_ns"])
        self.bdevErrorsRead = IOCounters.u64(fields["bdev_errors_read"])
        self.bdevErrorsWritten = IOCounters.u64(fields["bdev_errors_written"])
    }

    private static func u64(_ s: String?) -> UInt64 {
        guard let s = s else { return 0 }
        return UInt64(s) ?? 0
    }

    /// Average size of a single read in bytes (cumulative). 0 if no reads yet.
    public var avgReadSize: UInt64 {
        opsRead == 0 ? 0 : bytesRead / opsRead
    }

    /// Average size of a single write in bytes (cumulative).
    public var avgWriteSize: UInt64 {
        opsWritten == 0 ? 0 : bytesWritten / opsWritten
    }

    /// Average read latency (nanoseconds, cumulative).
    public var avgReadLatencyNs: UInt64 {
        opsRead == 0 ? 0 : readLatencyNs / opsRead
    }

    /// Average write latency (nanoseconds, cumulative).
    public var avgWriteLatencyNs: UInt64 {
        opsWritten == 0 ? 0 : writeLatencyNs / opsWritten
    }

    /// Bdev → file amplification factor (physical / logical) for reads.
    /// 1.0 means perfect alignment; 4.0 means 4× more bytes hit the
    /// device than the user asked for (typical metadata-heavy workload).
    /// Returns nil while there's no logical I/O yet.
    public var readAmplification: Double? {
        guard bytesRead > 0 else { return nil }
        return Double(bdevBytesRead) / Double(bytesRead)
    }

    public var writeAmplification: Double? {
        guard bytesWritten > 0 else { return nil }
        return Double(bdevBytesWritten) / Double(bytesWritten)
    }
}

/// One throughput sample, derived from the delta between two
/// successive `io.stats` snapshots. `bytesPerSec` is "bytes per second"
/// — already normalised, so the sparkline doesn't need to divide.
public struct IOSample: Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let readBytesPerSec: Double
    public let writeBytesPerSec: Double
    public let bdevReadBytesPerSec: Double
    public let bdevWriteBytesPerSec: Double

    public init(
        timestamp: Date,
        readBytesPerSec: Double,
        writeBytesPerSec: Double,
        bdevReadBytesPerSec: Double,
        bdevWriteBytesPerSec: Double
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.readBytesPerSec = readBytesPerSec
        self.writeBytesPerSec = writeBytesPerSec
        self.bdevReadBytesPerSec = bdevReadBytesPerSec
        self.bdevWriteBytesPerSec = bdevWriteBytesPerSec
    }
}

/// Rolling I/O stats for one subject — the structure the detail view
/// renders directly. Owns both the latest cumulative snapshot AND the
/// derived per-second samples. Capped at `sampleCap` (~2 min at 1 Hz)
/// so memory stays bounded for long-running mounts.
public struct IOStats: Equatable, Hashable, Sendable {
    public static let sampleCap = 120

    /// How many seconds of history the sparkline should show. Older
    /// samples stay in `samples` (capped by `sampleCap`) so changing
    /// this constant doesn't lose data, but the rendered window is
    /// fixed so the chart doesn't compress an ever-growing time range
    /// into the same pixel width as the buffer fills.
    public static let displayWindowSeconds: TimeInterval = 60.0

    /// Maximum age (in seconds) of the latest sample before the live
    /// throughput readout is treated as stale and reported as 0. Set
    /// just above the extensions' 1 Hz emit cadence so a single
    /// dropped tick doesn't blip to zero, but a genuine idle period
    /// (or a dead extension) decays the rate display naturally.
    /// All three IOStatsCollectors (FileProvider/EXT4/NTFS)
    /// self-suppress emissions when counters are unchanged, which
    /// would otherwise leave `samples.last` frozen at whatever rate
    /// was last observed.
    public static let staleThresholdSeconds: TimeInterval = 3.0

    public var cumulative: IOCounters = .init()
    public var samples: [IOSample] = []
    public var lastUpdate: Date? = nil

    public init() {}

    /// Absorb a new cumulative snapshot from the extension. Computes a
    /// throughput sample from the delta against the previous snapshot
    /// and appends it. Two reset cases are handled:
    ///   - Counters went backwards (extension respawn) → drop the
    ///     previous baseline, store the new snapshot, no sample.
    ///   - Time delta is zero or negative → store snapshot, no sample.
    public mutating func absorb(_ snapshot: IOCounters, at now: Date = Date()) {
        defer {
            cumulative = snapshot
            lastUpdate = now
        }

        guard let last = lastUpdate else {
            return
        }
        let dt = now.timeIntervalSince(last)
        guard dt > 0 else { return }

        // Reset detection: if any of the four headline counters
        // decreased, treat the whole snapshot as a new baseline.
        if snapshot.bytesRead < cumulative.bytesRead
            || snapshot.bytesWritten < cumulative.bytesWritten
            || snapshot.bdevBytesRead < cumulative.bdevBytesRead
            || snapshot.bdevBytesWritten < cumulative.bdevBytesWritten {
            return
        }

        let dRead = Double(snapshot.bytesRead &- cumulative.bytesRead)
        let dWrite = Double(snapshot.bytesWritten &- cumulative.bytesWritten)
        let dBdevRead = Double(snapshot.bdevBytesRead &- cumulative.bdevBytesRead)
        let dBdevWrite = Double(snapshot.bdevBytesWritten &- cumulative.bdevBytesWritten)

        let sample = IOSample(
            timestamp: now,
            readBytesPerSec: dRead / dt,
            writeBytesPerSec: dWrite / dt,
            bdevReadBytesPerSec: dBdevRead / dt,
            bdevWriteBytesPerSec: dBdevWrite / dt
        )
        samples.append(sample)
        if samples.count > Self.sampleCap {
            samples.removeFirst(samples.count - Self.sampleCap)
        }
    }

    /// True when the most recent sample is older than
    /// `staleThresholdSeconds`. Used by the live-throughput getters
    /// below so an idle (or dead) extension's last sample doesn't
    /// keep rendering as the "current" rate forever.
    public func isStale(at now: Date = Date()) -> Bool {
        guard let ts = samples.last?.timestamp else { return true }
        return now.timeIntervalSince(ts) > Self.staleThresholdSeconds
    }

    /// Latest sample's read+write throughput, or 0 if no samples yet
    /// OR the latest sample is older than `staleThresholdSeconds`.
    /// Pass `now` from a `TimelineView` so the view re-evaluates the
    /// staleness check on each tick — without that, SwiftUI won't
    /// re-render until something else publishes.
    public func currentReadBytesPerSec(at now: Date = Date()) -> Double {
        isStale(at: now) ? 0 : (samples.last?.readBytesPerSec ?? 0)
    }
    public func currentWriteBytesPerSec(at now: Date = Date()) -> Double {
        isStale(at: now) ? 0 : (samples.last?.writeBytesPerSec ?? 0)
    }
    public func currentBdevReadBytesPerSec(at now: Date = Date()) -> Double {
        isStale(at: now) ? 0 : (samples.last?.bdevReadBytesPerSec ?? 0)
    }
    public func currentBdevWriteBytesPerSec(at now: Date = Date()) -> Double {
        isStale(at: now) ? 0 : (samples.last?.bdevWriteBytesPerSec ?? 0)
    }

    /// Sub-slice of `samples` whose timestamp falls within the rolling
    /// display window ending at `now`. The slice is monotonic in time
    /// (samples are append-only) so we binary-search the cutoff. Used
    /// by the detail view so the sparkline shows a fixed time range
    /// (last 60s by default) instead of compressing the whole buffer
    /// into the chart width as samples accumulate.
    public func recentSamples(at now: Date = Date(),
                              window: TimeInterval = IOStats.displayWindowSeconds) -> ArraySlice<IOSample> {
        guard !samples.isEmpty else { return samples[0..<0] }
        let cutoff = now.addingTimeInterval(-window)
        var lo = 0
        var hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].timestamp < cutoff {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return samples[lo...]
    }

    /// Peak throughput observed inside the display window — used by
    /// the sparkline as its y-axis scale. Window-scoped (not all-time)
    /// so a one-off spike that's already scrolled past doesn't squash
    /// the currently-visible signal flat against the baseline. MUST
    /// stay consistent with the sample array passed alongside it: if
    /// peak returns 0 while the slice still contains a 352 KB/s
    /// reading, the sparkline path computes `y = h - (352000/1) * h`,
    /// which is a huge negative number, and the stroke is drawn far
    /// above its frame (SwiftUI doesn't clip Path strokes by default).
    public func peakReadBytesPerSec(at now: Date = Date(),
                                    window: TimeInterval = IOStats.displayWindowSeconds) -> Double {
        recentSamples(at: now, window: window).map { $0.readBytesPerSec }.max() ?? 0
    }
    public func peakWriteBytesPerSec(at now: Date = Date(),
                                     window: TimeInterval = IOStats.displayWindowSeconds) -> Double {
        recentSamples(at: now, window: window).map { $0.writeBytesPerSec }.max() ?? 0
    }
    public func peakBdevReadBytesPerSec(at now: Date = Date(),
                                        window: TimeInterval = IOStats.displayWindowSeconds) -> Double {
        recentSamples(at: now, window: window).map { $0.bdevReadBytesPerSec }.max() ?? 0
    }
    public func peakBdevWriteBytesPerSec(at now: Date = Date(),
                                         window: TimeInterval = IOStats.displayWindowSeconds) -> Double {
        recentSamples(at: now, window: window).map { $0.bdevWriteBytesPerSec }.max() ?? 0
    }
}
