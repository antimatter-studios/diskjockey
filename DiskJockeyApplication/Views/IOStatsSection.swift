//
// IOStatsSection.swift — reusable per-mount I/O activity panel.
//
// Renders the same chrome for an FSKit-attached disk and for a
// FileProvider direct mount: live throughput, totals, ops, average
// request size, average latency, plus two sliding sparklines (read +
// write). Both detail views feed it the same `IOStats` struct, so the
// rendering code is unconditional.
//
// Sparklines are drawn with raw SwiftUI `Path` so we don't pull in the
// Charts framework — keeps the binary small and avoids the macOS-13
// availability gate the rest of the app doesn't have. The y-axis on
// each line auto-scales to the peak observed in the sample window so a
// quiet idle volume isn't drawn as a flat-zero line that hides spikes.
//

import SwiftUI

/// Per-subject I/O activity panel. Subject-agnostic — pass an
/// `IOStats` and the section renders identically for an attached disk
/// or a direct mount. The "physical" track is rendered only when the
/// caller opts in, since FileProvider doesn't have a block-device
/// equivalent.
struct IOStatsSection: View {
    let stats: IOStats
    /// Show the bdev (physical) track in addition to the file (logical)
    /// track. FSKit volumes set true; FileProvider sets false (no
    /// underlying block device — the bdev_* counters are always zero).
    let showPhysical: Bool

    var body: some View {
        // 1 Hz tick drives the staleness recompute on the live-rate
        // getters. Without this, SwiftUI only re-renders when the
        // model publishes — and once the extension stops emitting
        // io.stats events (idle volumes self-suppress), the displayed
        // rate would freeze at the last observed value forever.
        TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
            content(now: ctx.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("File activity")
                    .font(.headline)
                Spacer()
                if let last = stats.lastUpdate {
                    Text("updated \(Self.relative(last, relativeTo: now))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("waiting for first sample…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // Live throughput row — current rate + sparkline side by side.
            // Sparkline reads only the windowed slice so it shows a fixed
            // time range (last `displayWindowSeconds`) instead of the
            // whole buffer compressed into the chart width.
            let window = stats.recentSamples(at: now)
            HStack(spacing: 14) {
                throughputCard(
                    title: "Read",
                    bytesPerSec: stats.currentReadBytesPerSec(at: now),
                    samples: window.map { $0.readBytesPerSec },
                    peak: stats.peakReadBytesPerSec(at: now),
                    color: .blue,
                    icon: "arrow.down.circle.fill"
                )
                throughputCard(
                    title: "Write",
                    bytesPerSec: stats.currentWriteBytesPerSec(at: now),
                    samples: window.map { $0.writeBytesPerSec },
                    peak: stats.peakWriteBytesPerSec(at: now),
                    color: .orange,
                    icon: "arrow.up.circle.fill"
                )
            }

            // Cumulative + averages grid
            statsGrid()

            if showPhysical {
                Divider().padding(.vertical, 4)
                physicalTrack(now: now)
            }
        }
    }

    // MARK: - Throughput card with embedded sparkline

    @ViewBuilder
    private func throughputCard(
        title: String,
        bytesPerSec: Double,
        samples: [Double],
        peak: Double,
        color: Color,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(icon).foregroundStyle(color)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(Self.rate(bytesPerSec))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(color)
            }
            Sparkline(samples: samples, peak: peak, color: color)
                .frame(height: 38)
                // Hard-clip — Path strokes don't honor parent frames
                // by default. Without this, any inconsistency between
                // `peak` and `samples` (e.g. a stale-peak override
                // pulling the y-scale to 1 while samples still contain
                // KB/s readings) draws the curve far above the card,
                // streaking blue bars across the whole window.
                .clipped()
            HStack {
                Text("peak \(Self.rate(peak))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("last \(Int(IOStats.displayWindowSeconds))s · \(samples.count) samples")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.06)))
    }

    // MARK: - Cumulative + averages

    @ViewBuilder
    private func statsGrid() -> some View {
        let c = stats.cumulative
        HStack(alignment: .top, spacing: 32) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    gridLabel("Bytes read")
                    gridValue(Self.bytes(c.bytesRead))
                    gridLabel("Bytes written")
                    gridValue(Self.bytes(c.bytesWritten))
                }
                GridRow {
                    gridLabel("Read ops")
                    gridValue(Self.count(c.opsRead))
                    gridLabel("Write ops")
                    gridValue(Self.count(c.opsWritten))
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    gridLabel("Avg read size")
                    gridValue(c.opsRead == 0 ? "—" : Self.bytes(c.avgReadSize))
                    gridLabel("Avg write size")
                    gridValue(c.opsWritten == 0 ? "—" : Self.bytes(c.avgWriteSize))
                }
                GridRow {
                    gridLabel("Avg read latency")
                    gridValue(c.opsRead == 0 ? "—" : Self.duration(c.avgReadLatencyNs))
                    gridLabel("Avg write latency")
                    gridValue(c.opsWritten == 0 ? "—" : Self.duration(c.avgWriteLatencyNs))
                }
            }
        }
        if c.errorsRead > 0 || c.errorsWritten > 0 {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    gridLabel("Read errors")
                    Text(Self.count(c.errorsRead))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(c.errorsRead > 0 ? .red : .primary)
                    gridLabel("Write errors")
                    Text(Self.count(c.errorsWritten))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(c.errorsWritten > 0 ? .red : .primary)
                }
            }
        }
    }

    @ViewBuilder
    private func gridLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
    }

    @ViewBuilder
    private func gridValue(_ text: String) -> some View {
        Text(text)
            .font(.callout.monospacedDigit())
            .gridColumnAlignment(.leading)
    }

    // MARK: - Physical (block-device) track

    @ViewBuilder
    private func physicalTrack(now: Date) -> some View {
        let c = stats.cumulative
        let window = stats.recentSamples(at: now)
        VStack(alignment: .leading, spacing: 6) {
            Text("Physical I/O (block device)")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 14) {
                throughputCard(
                    title: "Bdev read",
                    bytesPerSec: stats.currentBdevReadBytesPerSec(at: now),
                    samples: window.map { $0.bdevReadBytesPerSec },
                    peak: stats.peakBdevReadBytesPerSec(at: now),
                    color: .teal,
                    icon: "internaldrive"
                )
                throughputCard(
                    title: "Bdev write",
                    bytesPerSec: stats.currentBdevWriteBytesPerSec(at: now),
                    samples: window.map { $0.bdevWriteBytesPerSec },
                    peak: stats.peakBdevWriteBytesPerSec(at: now),
                    color: .purple,
                    icon: "internaldrive.fill"
                )
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    gridLabel("Bdev bytes read")
                    gridValue(Self.bytes(c.bdevBytesRead))
                    gridLabel("Bdev bytes written")
                    gridValue(Self.bytes(c.bdevBytesWritten))
                }
                GridRow {
                    gridLabel("Bdev ops read")
                    gridValue(Self.count(c.bdevOpsRead))
                    gridLabel("Bdev ops written")
                    gridValue(Self.count(c.bdevOpsWritten))
                }
                if let amp = c.readAmplification, amp.isFinite {
                    GridRow {
                        gridLabel("Read amplification")
                        Text(String(format: "%.2f×", amp))
                            .font(.callout.monospacedDigit())
                            .help("Bytes pulled from device ÷ bytes returned to apps. >1 means metadata + alignment overhead.")
                        if let wamp = c.writeAmplification, wamp.isFinite {
                            gridLabel("Write amplification")
                            Text(String(format: "%.2f×", wamp))
                                .font(.callout.monospacedDigit())
                        } else {
                            gridLabel("Write amplification")
                            gridValue("—")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Formatting

    private static func rate(_ bps: Double) -> String {
        if bps < 1 { return "0 B/s" }
        return "\(bytes(UInt64(bps)))/s"
    }

    /// Human-readable byte count using 1024-based maths and Finder-style
    /// labels (B / KB / MB / GB / TB). Keeps integer precision under
    /// 2 KB so "1234 B" reads cleanly.
    static func bytes(_ n: UInt64) -> String {
        let labels = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = Double(n)
        var i = 0
        while i < labels.count - 1 && v >= 2048 {
            v /= 1024
            i += 1
        }
        return i == 0 ? "\(Int(v)) \(labels[i])"
                      : String(format: "%.1f %@", v, labels[i])
    }

    private static func count(_ n: UInt64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static func duration(_ ns: UInt64) -> String {
        // Sub-microsecond reads happen on cached metadata; otherwise
        // most ops are µs–ms. Pick the unit that keeps the leading
        // digit between 1 and 999.
        if ns < 1_000 { return "\(ns) ns" }
        if ns < 1_000_000 { return String(format: "%.1f µs", Double(ns) / 1_000) }
        if ns < 1_000_000_000 { return String(format: "%.1f ms", Double(ns) / 1_000_000) }
        return String(format: "%.2f s", Double(ns) / 1_000_000_000)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private static func relative(_ d: Date, relativeTo now: Date = Date()) -> String {
        return relativeFormatter.localizedString(for: d, relativeTo: now)
    }
}

/// Path-based sparkline. Auto-scales the y-axis to `peak` (with a 1
/// floor so a flat-zero series still draws a baseline). Samples are
/// laid out left-to-right in arrival order; on next tick the buffer
/// shifts one sample, so the line "slides" naturally without us
/// animating anything.
struct Sparkline: View {
    let samples: [Double]
    let peak: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // Floor the y-scale at 1 to avoid divide-by-zero AND to keep
            // a quiet line drawing along the bottom (instead of NaN).
            let scale = max(peak, 1)
            // Leave one column of horizontal space so the rightmost
            // sample doesn't get clipped.
            let cap = max(samples.count - 1, 1)

            ZStack(alignment: .bottomLeading) {
                // Baseline rule for visual context.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h - 0.5))
                    p.addLine(to: CGPoint(x: w, y: h - 0.5))
                }
                .stroke(color.opacity(0.15), lineWidth: 1)

                // Filled area under the curve (faint).
                Path { p in
                    guard !samples.isEmpty else { return }
                    p.move(to: CGPoint(x: 0, y: h))
                    for (i, v) in samples.enumerated() {
                        let x = CGFloat(i) / CGFloat(cap) * w
                        let y = h - CGFloat(v / scale) * h
                        p.addLine(to: CGPoint(x: x, y: y))
                    }
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.closeSubpath()
                }
                .fill(color.opacity(0.18))

                // Stroke on top.
                Path { p in
                    guard let first = samples.first else { return }
                    p.move(to: CGPoint(
                        x: 0,
                        y: h - CGFloat(first / scale) * h
                    ))
                    for (i, v) in samples.enumerated() {
                        let x = CGFloat(i) / CGFloat(cap) * w
                        let y = h - CGFloat(v / scale) * h
                        p.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5,
                                                   lineCap: .round,
                                                   lineJoin: .round))
            }
        }
    }
}
