//
//  IOStatsRecorderTests.swift — the per-mount I/O counters, their wire
//  format, and the four near-identical recorders.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  This type exists BECAUSE of a copy-paste problem: its own header says it
//  "replaces three near-identical per-extension copies". What it kept is
//  four near-identical methods — recordRead, recordWrite, recordBdevRead,
//  recordBdevWrite — each incrementing a different triple of fields out of
//  sixteen, with an error branch that must increment the error counter and
//  NOTHING else. That shape is only correct by inspection, and nothing
//  inspected it.
//
//  The consequence of getting one wrong is a wrong number in the UI, which
//  is the least alarming way for a defect to present: no crash, no error,
//  just a sparkline that lies. So the tests below assert per-field that a
//  recorder touches exactly the three counters it owns and leaves the other
//  thirteen alone.
//
//  `asFields()` is a wire format read by the host-side `IOCounters(fields:)`
//  decoder, which is not compiled against this file. The key names and the
//  field count are pinned for that reason.
//
//  Host-free: no mount, no block device, no extension.
//

import Foundation
import Testing
@testable import DiskJockeyLibrary

// MARK: - Helpers

/// Collects the dictionaries handed to a recorder's emitter. The emitter is
/// called from the recorder's own dispatch queue, so this locks.
private final class EmitCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String: String]] = []

    var emissions: [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    var count: Int { emissions.count }
    var last: [String: String]? { emissions.last }

    func take(_ fields: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        storage.append(fields)
    }
}

/// The sixteen wire keys, spelled out here so a rename in either place is a
/// failure rather than a silent divergence from the host-side decoder.
private let wireKeys: Set<String> = [
    "bytes_read", "bytes_written", "ops_read", "ops_written",
    "errors_read", "errors_written", "read_latency_ns", "write_latency_ns",
    "bdev_bytes_read", "bdev_bytes_written", "bdev_ops_read", "bdev_ops_written",
    "bdev_read_latency_ns", "bdev_write_latency_ns",
    "bdev_errors_read", "bdev_errors_written",
]

/// Every wire key whose value is not "0", i.e. what a recorder actually
/// touched. Comparing these sets is what catches a recorder incrementing a
/// counter belonging to another.
private func nonZeroKeys(_ counters: IOStatsCounters) -> Set<String> {
    Set(counters.asFields().filter { $0.value != "0" }.map(\.key))
}

// MARK: - The wire format

@Suite("IOStatsCounters.asFields")
struct IOStatsWireFormatTests {

    @Test func itCarriesExactlySixteenNamedFields() {
        let fields = IOStatsCounters().asFields()
        #expect(Set(fields.keys) == wireKeys,
                "wire keys drifted: extra \(Set(fields.keys).subtracting(wireKeys)), missing \(wireKeys.subtracting(Set(fields.keys)))")
        #expect(fields.count == 16)
    }

    @Test func freshCountersRenderAsZeroesRatherThanAbsences() {
        let fields = IOStatsCounters().asFields()
        #expect(fields.values.allSatisfy { $0 == "0" })
        #expect(fields.count == 16,
                "an idle mount still emits every field; the host decoder is one path for FSKit and FileProvider alike")
    }

    /// Values are decimal strings, because the whole log wire format is
    /// map<string,string> and the host coerces back.
    @Test func valuesAreDecimalStringsTheHostCanCoerce() {
        var c = IOStatsCounters()
        c.bytesRead = 1
        c.bdevWriteLatencyNs = UInt64.max
        let fields = c.asFields()
        #expect(fields["bytes_read"] == "1")
        #expect(fields["bdev_write_latency_ns"] == "18446744073709551615")
        for (key, value) in fields {
            #expect(UInt64(value) != nil, "\(key) = \(value) does not parse as UInt64")
        }
    }

    /// Each of the sixteen struct fields must reach its own wire key. Set one
    /// at a time and check that exactly one key is non-zero.
    @Test func everyStructFieldMapsToItsOwnKey() {
        let cases: [(String, (inout IOStatsCounters) -> Void)] = [
            ("bytes_read",            { $0.bytesRead = 7 }),
            ("bytes_written",         { $0.bytesWritten = 7 }),
            ("ops_read",              { $0.opsRead = 7 }),
            ("ops_written",           { $0.opsWritten = 7 }),
            ("errors_read",           { $0.errorsRead = 7 }),
            ("errors_written",        { $0.errorsWritten = 7 }),
            ("read_latency_ns",       { $0.readLatencyNs = 7 }),
            ("write_latency_ns",      { $0.writeLatencyNs = 7 }),
            ("bdev_bytes_read",       { $0.bdevBytesRead = 7 }),
            ("bdev_bytes_written",    { $0.bdevBytesWritten = 7 }),
            ("bdev_ops_read",         { $0.bdevOpsRead = 7 }),
            ("bdev_ops_written",      { $0.bdevOpsWritten = 7 }),
            ("bdev_read_latency_ns",  { $0.bdevReadLatencyNs = 7 }),
            ("bdev_write_latency_ns", { $0.bdevWriteLatencyNs = 7 }),
            ("bdev_errors_read",      { $0.bdevErrorsRead = 7 }),
            ("bdev_errors_written",   { $0.bdevErrorsWritten = 7 }),
        ]
        #expect(cases.count == 16, "one case per wire key")
        for (key, mutate) in cases {
            var c = IOStatsCounters()
            mutate(&c)
            #expect(nonZeroKeys(c) == [key],
                    "setting the field behind \(key) produced \(nonZeroKeys(c))")
        }
    }

    @Test func countersCompareByValue() {
        var a = IOStatsCounters(), b = IOStatsCounters()
        #expect(a == b, "Equatable is what the duplicate-emit suppression keys on")
        a.opsRead = 1
        #expect(a != b)
        b.opsRead = 1
        #expect(a == b)
    }
}

// MARK: - The hot-path recorders

@Suite("hot-path recorders")
struct IOStatsRecorderHotPathTests {

    /// Drive one recorder method, then force a flush and return what the
    /// emitter was handed.
    private func fieldsAfter(_ body: (IOStatsRecorder) -> Void) -> [String: String] {
        let collector = EmitCollector()
        let recorder = IOStatsRecorder(label: "test") { collector.take($0) }
        body(recorder)
        recorder.stop()          // forces a final flush
        return collector.last ?? [:]
    }

    private func nonZero(_ fields: [String: String]) -> Set<String> {
        Set(fields.filter { $0.value != "0" }.map(\.key))
    }

    /// EACH RECORDER OWNS EXACTLY THREE COUNTERS. This is the check the four
    /// near-identical methods needed: a bdev recorder that incremented a
    /// logical counter would show up as a plausible number in the wrong
    /// half of the UI, with nothing else to notice it.
    @Test func aSuccessfulReadTouchesOnlyItsOwnThreeCounters() {
        let fields = fieldsAfter { $0.recordRead(bytes: 4096, latencyNs: 500, error: false) }
        #expect(nonZero(fields) == ["bytes_read", "ops_read", "read_latency_ns"])
        #expect(fields["bytes_read"] == "4096")
        #expect(fields["ops_read"] == "1")
        #expect(fields["read_latency_ns"] == "500")
    }

    @Test func aSuccessfulWriteTouchesOnlyItsOwnThreeCounters() {
        let fields = fieldsAfter { $0.recordWrite(bytes: 512, latencyNs: 90, error: false) }
        #expect(nonZero(fields) == ["bytes_written", "ops_written", "write_latency_ns"])
        #expect(fields["bytes_written"] == "512")
        #expect(fields["ops_written"] == "1")
        #expect(fields["write_latency_ns"] == "90")
    }

    @Test func aSuccessfulBlockDeviceReadStaysOnTheBdevSide() {
        let fields = fieldsAfter { $0.recordBdevRead(bytes: 8192, latencyNs: 12, error: false) }
        #expect(nonZero(fields) == ["bdev_bytes_read", "bdev_ops_read", "bdev_read_latency_ns"],
                "a block-device read must not move the logical counters")
    }

    @Test func aSuccessfulBlockDeviceWriteStaysOnTheBdevSide() {
        let fields = fieldsAfter { $0.recordBdevWrite(bytes: 8192, latencyNs: 12, error: false) }
        #expect(nonZero(fields) == ["bdev_bytes_written", "bdev_ops_written", "bdev_write_latency_ns"])
    }

    /// AN ERRORED OPERATION MOVED NO BYTES. It increments the error counter
    /// and nothing else — not the op count, not the byte count, and not the
    /// latency total, which would otherwise pull the average latency towards
    /// however long the failure took.
    @Test("an error increments only its error counter",
          arguments: [("errors_read",         0),
                      ("errors_written",      1),
                      ("bdev_errors_read",    2),
                      ("bdev_errors_written", 3)])
    func errorsCountAlone(key: String, which: Int) {
        let fields = fieldsAfter { r in
            switch which {
            case 0: r.recordRead(bytes: 4096, latencyNs: 999, error: true)
            case 1: r.recordWrite(bytes: 4096, latencyNs: 999, error: true)
            case 2: r.recordBdevRead(bytes: 4096, latencyNs: 999, error: true)
            default: r.recordBdevWrite(bytes: 4096, latencyNs: 999, error: true)
            }
        }
        #expect(nonZero(fields) == [key],
                "an errored operation moved bytes or latency: \(nonZero(fields))")
        #expect(fields[key] == "1")
    }

    /// `max(0, bytes)` is a guard, and this is what it guards against: a
    /// negative count from a driver would otherwise convert into an enormous
    /// UInt64 and the byte total would jump by exabytes.
    @Test func aNegativeByteCountContributesNothingRatherThanWrapping() {
        let fields = fieldsAfter { $0.recordRead(bytes: -1, latencyNs: 5, error: false) }
        #expect(fields["bytes_read"] == "0", "a negative byte count wrapped into the total")
        #expect(fields["ops_read"] == "1", "the operation still happened, so it still counts")
        #expect(fields["read_latency_ns"] == "5")
    }

    /// `&+=` is a wrapping add, deliberately: a trap on overflow would crash
    /// a filesystem extension on a long-lived busy mount. Three adds of
    /// Int.max exceed UInt64.max, so this reaches the wrap.
    @Test func theTotalsWrapRatherThanTrapping() {
        let fields = fieldsAfter { r in
            for _ in 0..<3 { r.recordRead(bytes: Int.max, latencyNs: 0, error: false) }
        }
        let total = UInt64(fields["bytes_read"] ?? "x")
        #expect(total != nil, "bytes_read stopped being a number")
        // 3 * Int.max mod 2^64
        let expected = UInt64(Int.max) &* 3
        #expect(total == expected, "wrapping arithmetic changed: got \(total as UInt64?), expected \(expected)")
        #expect(fields["ops_read"] == "3")
    }

    @Test func repeatedOperationsAccumulate() {
        let fields = fieldsAfter { r in
            for _ in 0..<10 { r.recordRead(bytes: 100, latencyNs: 7, error: false) }
            for _ in 0..<3  { r.recordRead(bytes: 0, latencyNs: 0, error: true) }
        }
        #expect(fields["bytes_read"] == "1000")
        #expect(fields["ops_read"] == "10")
        #expect(fields["read_latency_ns"] == "70")
        #expect(fields["errors_read"] == "3")
    }

    /// The counters sit behind an unfair lock and the recorders are on the
    /// hot path, called from whatever thread FSKit hands them.
    @Test func concurrentRecordingLosesNothing() async {
        let collector = EmitCollector()
        let recorder = IOStatsRecorder(label: "race") { collector.take($0) }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask { recorder.recordRead(bytes: 10, latencyNs: 1, error: false) }
                group.addTask { recorder.recordBdevWrite(bytes: 3, latencyNs: 2, error: false) }
            }
        }
        recorder.stop()
        let fields = collector.last ?? [:]
        #expect(fields["ops_read"] == "200")
        #expect(fields["bytes_read"] == "2000")
        #expect(fields["read_latency_ns"] == "200")
        #expect(fields["bdev_ops_written"] == "200")
        #expect(fields["bdev_bytes_written"] == "600")
    }
}

// MARK: - Flushing

@Suite("flush behaviour")
struct IOStatsFlushTests {

    /// "On stop we force a final flush so the host sees the closing tally."
    /// Including from a recorder that was never started and never touched —
    /// the closing zero tally is still a message the host needs.
    @Test func stopAlwaysFlushesEvenWithNothingToSay() {
        let collector = EmitCollector()
        let recorder = IOStatsRecorder(label: "stop") { collector.take($0) }
        recorder.stop()
        #expect(collector.count == 1)
        #expect(collector.last?.values.allSatisfy { $0 == "0" } == true)
    }

    @Test func stopFlushesTheFinalTally() {
        let collector = EmitCollector()
        let recorder = IOStatsRecorder(label: "tally") { collector.take($0) }
        recorder.recordWrite(bytes: 77, latencyNs: 3, error: false)
        recorder.stop()
        #expect(collector.last?["bytes_written"] == "77")
    }

    /// "Idle volumes self-suppress." The first tick emits because there is
    /// no previous snapshot; every idle tick after it is suppressed. So an
    /// idle started recorder emits exactly once no matter how many times the
    /// timer fires, which is what keeps the NDJSON sink from being flooded
    /// by every mounted volume doing nothing.
    @Test func anIdleRecorderEmitsOnceHoweverManyTimesTheTimerFires() async throws {
        let collector = EmitCollector()
        let recorder = IOStatsRecorder(label: "idle") { collector.take($0) }
        recorder.start()
        // The cadence is 1 Hz; wait long enough for several ticks.
        try await Task.sleep(nanoseconds: 3_400_000_000)
        let duringRun = collector.count
        recorder.stop()
        #expect(duringRun == 1,
                "an idle recorder emitted \(duringRun) times; duplicate suppression is not working")
    }

    /// And activity between ticks is not suppressed.
    @Test func activityBetweenTicksIsEmitted() async throws {
        let collector = EmitCollector()
        let recorder = IOStatsRecorder(label: "busy") { collector.take($0) }
        recorder.start()
        try await Task.sleep(nanoseconds: 1_400_000_000)
        recorder.recordRead(bytes: 1, latencyNs: 1, error: false)
        try await Task.sleep(nanoseconds: 1_400_000_000)
        let duringRun = collector.count
        recorder.stop()
        #expect(duringRun >= 2, "a changed snapshot was suppressed (\(duringRun) emissions)")
    }

    /// THE PREFLUSH OVERLAY IS PERSISTED, which the comment gives the reason
    /// for: subsequent hot-path increments have to build on the
    /// authoritative numbers "rather than re-overlaying the deltas every
    /// tick". A hook that adds a constant each flush therefore produces a
    /// running total; if the overlay were not written back, every flush
    /// would report the same constant.
    @Test func thePreflushOverlayIsWrittenBackNotReapplied() {
        let collector = EmitCollector()
        let recorder = IOStatsRecorder(label: "overlay",
                                       emit: { collector.take($0) },
                                       preflush: { $0.bdevBytesRead &+= 100 })
        recorder.stop()
        #expect(collector.last?["bdev_bytes_read"] == "100")
        recorder.stop()
        #expect(collector.last?["bdev_bytes_read"] == "200",
                "the overlay was not persisted, so each flush re-applied it to the same base")
    }

    @Test func aPreflushSeesTheHotPathCountersAndCanCorrectThem() {
        let collector = EmitCollector()
        let recorder = IOStatsRecorder(label: "correct",
                                       emit: { collector.take($0) },
                                       preflush: { counters in
                                           // What FileProvider does: replace the
                                           // Swift-side guess with the Go-side truth.
                                           #expect(counters.bytesRead == 50)
                                           counters.bytesRead = 999
                                       })
        recorder.recordRead(bytes: 50, latencyNs: 1, error: false)
        recorder.stop()
        #expect(collector.last?["bytes_read"] == "999")
    }

    /// FSKit recorders pass nil, so that path has to work too.
    @Test func noPreflushIsFine() {
        let collector = EmitCollector()
        let recorder = IOStatsRecorder(label: "nohook", emit: { collector.take($0) }, preflush: nil)
        recorder.recordRead(bytes: 1, latencyNs: 1, error: false)
        recorder.stop()
        #expect(collector.last?["bytes_read"] == "1")
    }
}

// MARK: - Odds and ends

@Suite("IOStats helpers")
struct IOStatsHelperTests {

    /// The alias exists for the three per-extension copies this type
    /// replaced. Removing it would break their call sites silently at
    /// compile time in another target, so it is worth one line here.
    @Test func theBackCompatAliasStillNamesTheSameType() {
        #expect(IOStatsCollector.self == IOStatsRecorder.self)
    }

    @Test func monotonicNanosMovesForwardAndIsNotZero() {
        let a = monotonicNanos()
        #expect(a > 0)
        var b = monotonicNanos()
        var spins = 0
        while b == a && spins < 1_000_000 { b = monotonicNanos(); spins += 1 }
        #expect(b > a, "the clock did not advance in a million reads")
    }
}
