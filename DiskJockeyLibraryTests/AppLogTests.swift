//
//  AppLogTests.swift — the logging surface, its wire format, and the two
//  places consumers outside Swift depend on it.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  AppLog is the largest untested file in the library, and most of it is a
//  FORMAT rather than a behaviour — which is the kind of thing that breaks
//  quietly. Three consumers read what this produces:
//
//    * the host app's LogTailService / LogRepository, which tails the
//      NDJSON file and routes on `kind`, `fields` and `scope`;
//    * the UI's scope toggles, which enumerate `AppLogScope.all`;
//    * "backends outside Swift (Rust, Go)", which the header says "can
//      produce the same NDJSON wire format with plain file I/O".
//
//  None of those are compiled against this type. A renamed key, a changed
//  level spelling, or a scope missing from `all` is a silent break in
//  another process or another language.
//
//  HOW IT IS TESTED WITHOUT A CONTAINER. `AppLogSink` is a public protocol,
//  so the tests below plug in a capturing sink and read what was emitted.
//  `formatEvent` is `private static` and cannot be called directly at all;
//  it is exercised through `event(kind:fields:)`, which is the only way any
//  caller reaches it either.
//
//  NDJSONFileSink IS tested for real, in a temporary directory of the
//  test's own. Its `directory:` parameter exists for that: the default
//  resolves through `containerURL(forSecurityApplicationGroupIdentifier:)`,
//  which returns a real path even to a process holding no app-group
//  entitlement — measured, `~/Library/Group Containers/...` — so a test
//  cannot steer it by arranging for the container to be missing. The
//  choices were to write into the developer's own container, to duplicate
//  the sink's path logic here (the same defect shape as duplicating an
//  implementation: it passes while the real one is wrong), or to let the
//  caller say where. The parameter is defaulted, so no production call
//  site changed.
//
//  NOT TESTED HERE, DELIBERATELY: StderrSink (capturing fd 2 is fragile
//  enough to be worse than the coverage) and OSLogSink (its output goes to
//  the unified log, which is not readable back without entitlements).
//

import Foundation
import Testing
@testable import DiskJockeyLibrary

// MARK: - A sink that remembers

/// Collects every line it is handed. `AppLog` snapshots its sink array under
/// a lock and then emits outside it, so this has to be safe to call from
/// several threads at once.
private final class CapturingSink: AppLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AppLogLine] = []

    var lines: [AppLogLine] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    var last: AppLogLine? { lines.last }

    func emit(_ line: AppLogLine) {
        lock.lock(); defer { lock.unlock() }
        storage.append(line)
    }
}

private func makeLog(source: String = "test") -> (AppLog, CapturingSink) {
    let sink = CapturingSink()
    return (AppLog(source: source, sinks: [sink]), sink)
}

// MARK: - The wire format

@Suite("the NDJSON wire format")
struct AppLogLineFormatTests {

    /// UPPERCASE, AND ON THE WIRE. `level` is stored as the raw string, so
    /// these spellings are what a Rust or Go emitter has to produce and what
    /// LogRepository matches on.
    @Test func levelsAreTheUppercaseSpellings() {
        #expect(AppLogLevel.debug.rawValue == "DEBUG")
        #expect(AppLogLevel.info.rawValue == "INFO")
        #expect(AppLogLevel.warn.rawValue == "WARN")
        #expect(AppLogLevel.error.rawValue == "ERROR")
        #expect(AppLogLevel(rawValue: "WARN") == .warn)
        #expect(AppLogLevel(rawValue: "warn") == nil,
                "levels are case-sensitive on the wire; a lowercase one must not decode")
    }

    /// The timestamp shape is part of the format: internet date time with
    /// fractional seconds. A consumer parsing it with a stricter formatter
    /// breaks if the fraction disappears.
    @Test func theTimestampCarriesFractionalSeconds() throws {
        let line = AppLogLine(level: .info, source: "s", message: "m")
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z$"#
        #expect(line.ts.range(of: pattern, options: .regularExpression) != nil,
                "timestamp \(line.ts) is not internet-date-time with fractional seconds")
    }

    @Test func theLineCarriesTheEmittingProcess() {
        let line = AppLogLine(level: .info, source: "s", message: "m")
        #expect(line.pid == ProcessInfo.processInfo.processIdentifier)
    }

    @Test func aLineRoundTripsThroughJSON() throws {
        let line = AppLogLine(level: .warn, source: "ext4", message: "hello",
                              kind: "fsck.progress",
                              fields: ["bsd": "disk4s1", "done": "3", "total": "9"],
                              scope: AppLogScope.fsck)
        let back = try JSONDecoder().decode(AppLogLine.self,
                                            from: try JSONEncoder().encode(line))
        #expect(back.ts == line.ts)
        #expect(back.level == "WARN")
        #expect(back.source == "ext4")
        #expect(back.message == "hello")
        #expect(back.kind == "fsck.progress")
        #expect(back.fields == line.fields)
        #expect(back.scope == "fsck")
        #expect(back.pid == line.pid)
    }

    /// THE OPTIONAL KEYS ARE ABSENT, NOT NULL, when unset. Consumers in
    /// other languages have to handle one or the other, and which one is
    /// decided here.
    @Test func unsetOptionalsAreOmittedRatherThanEncodedAsNull() throws {
        let plain = AppLogLine(level: .info, source: "s", message: "m")
        let json = try #require(String(data: try JSONEncoder().encode(plain), encoding: .utf8))
        for key in ["kind", "fields", "scope"] {
            #expect(!json.contains("\"\(key)\""),
                    "\(key) is present in a plain line's JSON: \(json)")
        }
        // And the mandatory ones are there.
        for key in ["ts", "level", "source", "message", "pid"] {
            #expect(json.contains("\"\(key)\""), "\(key) is missing: \(json)")
        }
    }

    @Test func aLineDecodesFromJSONWithoutTheOptionalKeys() throws {
        let wire = #"{"ts":"2026-09-10T12:00:00.000Z","level":"INFO","source":"go","message":"m","pid":42}"#
        let line = try JSONDecoder().decode(AppLogLine.self, from: Data(wire.utf8))
        #expect(line.kind == nil)
        #expect(line.fields == nil)
        #expect(line.scope == nil)
        #expect(line.pid == 42, "a line produced by a non-Swift emitter must decode")
    }
}

// MARK: - Scopes

@Suite("AppLogScope")
struct AppLogScopeTests {

    /// `all` DRIVES THE UI, so a scope missing from it is a scope the user
    /// cannot toggle — and the constants and the list are maintained by
    /// hand, separately.
    @Test func everyScopeConstantIsInTheDisplayList() {
        // Spelled out rather than leading-dot: these are `static let`
        // Strings on a namespace enum, not enum cases, so `.probe` would
        // resolve against String and not compile.
        let constants: [String] = [AppLogScope.lifecycle, AppLogScope.probe,
                                   AppLogScope.fsck, AppLogScope.volume,
                                   AppLogScope.enumerate, AppLogScope.io,
                                   AppLogScope.stats]
        for scope in constants {
            #expect(AppLogScope.all.contains(scope),
                    "\(scope) is a canonical scope but is not in AppLogScope.all, so no panel can toggle it")
        }
        #expect(AppLogScope.all.count == constants.count,
                "AppLogScope.all has \(AppLogScope.all.count) entries against \(constants.count) constants")
    }

    @Test func theScopeStringsAreTheDocumentedOnes() {
        #expect(AppLogScope.all == ["lifecycle", "probe", "fsck", "volume",
                                    "enumerate", "io", "stats"])
    }

    @Test func noScopeIsListedTwice() {
        #expect(Set(AppLogScope.all).count == AppLogScope.all.count)
    }
}

// MARK: - Emitting

@Suite("AppLog emit")
struct AppLogEmitTests {

    @Test("each level helper emits its own level",
          arguments: [("debug", "DEBUG"), ("info", "INFO"), ("warn", "WARN"), ("error", "ERROR")])
    func levelHelpers(name: String, expected: String) throws {
        let (log, sink) = makeLog()
        switch name {
        case "debug": log.debug("m")
        case "info":  log.info("m")
        case "warn":  log.warn("m")
        default:      log.error("m")
        }
        let line = try #require(sink.last)
        #expect(line.level == expected)
        #expect(line.message == "m")
        #expect(line.kind == nil, "a plain message is not a structured event")
    }

    @Test func theSourceIsStampedOnEveryLine() throws {
        let (log, sink) = makeLog(source: "fileprovider")
        log.info("one")
        log.warn("two")
        #expect(sink.lines.count == 2)
        #expect(sink.lines.allSatisfy { $0.source == "fileprovider" })
    }

    /// "One call site, N sinks" is the file's opening claim.
    @Test func everySinkReceivesEveryLine() {
        let a = CapturingSink(), b = CapturingSink(), c = CapturingSink()
        let log = AppLog(source: "s", sinks: [a, b, c])
        log.info("m")
        #expect(a.lines.count == 1)
        #expect(b.lines.count == 1)
        #expect(c.lines.count == 1)
    }

    @Test func configureSwapsTheSinkList() {
        let before = CapturingSink(), after = CapturingSink()
        let log = AppLog(source: "s", sinks: [before])
        log.info("first")
        log.configure([after])
        log.info("second")
        #expect(before.lines.map(\.message) == ["first"],
                "a replaced sink must stop receiving")
        #expect(after.lines.map(\.message) == ["second"])
    }

    @Test func configuringNoSinksDropsLinesWithoutFailing() {
        let (log, sink) = makeLog()
        log.configure([])
        log.info("into the void")
        #expect(sink.lines.isEmpty)
    }

    /// AppLog snapshots its sinks under a lock and emits outside it, so
    /// concurrent callers must not lose lines.
    @Test func concurrentEmitsAllArrive() async {
        let (log, sink) = makeLog()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask { log.info("m\(i)") }
            }
        }
        #expect(sink.lines.count == 200)
        #expect(Set(sink.lines.map(\.message)).count == 200, "lines were lost or duplicated")
    }
}

// MARK: - Structured events

@Suite("structured events")
struct AppLogEventTests {

    /// THE DERIVED MESSAGE IS SORTED, which is what makes it reproducible:
    /// dictionary order is not defined, so an unsorted rendering would
    /// produce a different human-readable line every run.
    @Test func theDerivedMessageIsKindThenFieldsInKeyOrder() throws {
        let (log, sink) = makeLog()
        log.event(kind: "fsck.progress", fields: ["total": "9", "bsd": "disk4s1", "done": "3"])
        let line = try #require(sink.last)
        #expect(line.message == "fsck.progress bsd=disk4s1 done=3 total=9")
    }

    @Test func repeatedRenderingsOfTheSameFieldsAreIdentical() {
        let (log, sink) = makeLog()
        let fields = ["z": "1", "a": "2", "m": "3", "b": "4", "y": "5"]
        for _ in 0..<12 { log.event(kind: "k", fields: fields) }
        #expect(Set(sink.lines.map(\.message)).count == 1,
                "the derived message is not stable across emits: \(Set(sink.lines.map(\.message)))")
    }

    @Test func anEventWithNoFieldsIsJustItsKind() throws {
        let (log, sink) = makeLog()
        log.event(kind: "fsck.start")
        let line = try #require(sink.last)
        #expect(line.message == "fsck.start")
        #expect(line.fields == [:])
    }

    @Test func anExplicitMessageWinsButTheStructureSurvives() throws {
        let (log, sink) = makeLog()
        log.event(kind: "volume.dirty", fields: ["bsd": "disk4s1"],
                  message: "the journal needs replaying")
        let line = try #require(sink.last)
        #expect(line.message == "the journal needs replaying")
        #expect(line.kind == "volume.dirty", "an overridden message must not drop the kind")
        #expect(line.fields == ["bsd": "disk4s1"])
    }

    @Test func anEventIsInfoUnlessToldOtherwise() throws {
        let (log, sink) = makeLog()
        log.event(kind: "k")
        #expect(try #require(sink.last).level == "INFO")
        log.event(kind: "k", level: .error)
        #expect(try #require(sink.last).level == "ERROR")
    }

    @Test func theScopeIsCarriedThrough() throws {
        let (log, sink) = makeLog()
        log.event(kind: "k", scope: AppLogScope.io)
        #expect(try #require(sink.last).scope == "io")
        log.info("plain", scope: AppLogScope.lifecycle)
        #expect(try #require(sink.last).scope == "lifecycle")
    }
}

// MARK: - TaggedLogger

@Suite("TaggedLogger")
struct TaggedLoggerTests {

    /// The whole point: consumers can route on `fields["mount"]` without
    /// every call site remembering to pass it.
    @Test func itsFieldsAreAttachedToEveryLine() throws {
        let (log, sink) = makeLog()
        let tagged = TaggedLogger(log, fields: ["mount": "UUID-1"], kind: "fileprovider.mount")
        tagged.info("fetchContents")
        tagged.warn("slow")
        tagged.error("failed")
        tagged.debug("detail")
        #expect(sink.lines.count == 4)
        #expect(sink.lines.allSatisfy { $0.fields == ["mount": "UUID-1"] })
        #expect(sink.lines.allSatisfy { $0.kind == "fileprovider.mount" })
        #expect(sink.lines.map(\.level) == ["INFO", "WARN", "ERROR", "DEBUG"])
    }

    @Test func extraFieldsMergeOverTheDefaults() throws {
        let (log, sink) = makeLog()
        let tagged = TaggedLogger(log, fields: ["mount": "UUID-1", "bsd": "disk4"], kind: "k")
        tagged.event(fields: ["phase": "scan", "bsd": "disk9"])
        let line = try #require(sink.last)
        #expect(line.fields == ["mount": "UUID-1", "bsd": "disk9", "phase": "scan"],
                "a per-call field must win over the logger's default of the same name")
    }

    @Test func theKindCanBeOverriddenPerEvent() throws {
        let (log, sink) = makeLog()
        let tagged = TaggedLogger(log, fields: [:], kind: "fsck")
        tagged.event(kind: "fsck.progress")
        #expect(try #require(sink.last).kind == "fsck.progress")
        tagged.info("back to the default")
        #expect(try #require(sink.last).kind == "fsck")
    }

    @Test func theDefaultScopeAppliesAndAPerCallScopeOverridesIt() throws {
        let (log, sink) = makeLog()
        let tagged = TaggedLogger(log, fields: [:], kind: "k", scope: AppLogScope.fsck)
        tagged.info("uses the default")
        #expect(try #require(sink.last).scope == "fsck")
        tagged.info("overridden", scope: AppLogScope.io)
        #expect(try #require(sink.last).scope == "io")
        tagged.event(kind: "k2")
        #expect(try #require(sink.last).scope == "fsck",
                "an event with no scope must fall back to the logger's default")
    }

    @Test func aLoggerWithNoScopeLeavesLinesUntagged() throws {
        let (log, sink) = makeLog()
        TaggedLogger(log, fields: [:], kind: "k").info("m")
        #expect(try #require(sink.last).scope == nil,
                "an untagged line is visible in every panel; that is what nil means here")
    }
}

// MARK: - The file sink

@Suite("NDJSONFileSink")
struct NDJSONFileSinkTests {

    /// A directory this test owns, removed when it finishes.
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("applog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func records(in dir: URL, source: String) throws -> [AppLogLine] {
        let url = dir.appendingPathComponent("\(source).ndjson")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "no log file at \(url.path)")
        #expect(text.hasSuffix("\n"), "the last record must be newline-terminated too")
        return try text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { try JSONDecoder().decode(AppLogLine.self, from: Data($0.utf8)) }
    }

    /// One JSON object per line, newline-terminated, appended. This is the
    /// format LogTailService reads and the one a Rust or Go emitter has to
    /// match, so it is asserted on the bytes rather than on the API.
    @Test func itWritesOneNewlineTerminatedJSONObjectPerLine() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AppLog(source: "one", sinks: [NDJSONFileSink(source: "one", directory: dir)])
        log.info("first")
        log.event(kind: "fsck.progress", fields: ["done": "1"], scope: AppLogScope.fsck)
        log.error("third")

        let decoded = try records(in: dir, source: "one")
        #expect(decoded.count == 3, "expected three records, got \(decoded.count)")
        #expect(decoded.map(\.message) == ["first", "fsck.progress done=1", "third"],
                "records are out of order or malformed")
        #expect(decoded[1].kind == "fsck.progress")
        #expect(decoded[1].scope == "fsck")
        #expect(decoded[0].kind == nil)
        #expect(decoded.allSatisfy { $0.source == "one" })
    }

    /// A second sink on the same file appends rather than truncating —
    /// which is what has to happen when FSKit respawns an extension per
    /// resource operation, as the sink's own comment describes.
    @Test func aReopenedSinkAppendsRatherThanTruncating() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        AppLog(source: "re", sinks: [NDJSONFileSink(source: "re", directory: dir)]).info("before")
        AppLog(source: "re", sinks: [NDJSONFileSink(source: "re", directory: dir)]).info("after")
        #expect(try records(in: dir, source: "re").map(\.message) == ["before", "after"],
                "a respawned process truncated the log instead of appending")
    }

    /// Messages containing newlines would break NDJSON if written raw. JSON
    /// encoding escapes them, and that is worth pinning: one record must
    /// stay one line, or every consumer's line-splitting reader desyncs.
    @Test func aMessageContainingNewlinesStaysOneRecord() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AppLog(source: "nl", sinks: [NDJSONFileSink(source: "nl", directory: dir)])
        log.error("line one\nline two\nline three")
        let decoded = try records(in: dir, source: "nl")
        #expect(decoded.count == 1, "a multi-line message became \(decoded.count) NDJSON records")
        #expect(decoded[0].message == "line one\nline two\nline three")
    }

    /// The directory is created if it does not exist, which is what happens
    /// on a first launch into a fresh container.
    @Test func itCreatesADirectoryThatIsNotThereYet() throws {
        let parent = try scratch()
        defer { try? FileManager.default.removeItem(at: parent) }
        let nested = parent.appendingPathComponent("does/not/exist/yet", isDirectory: true)
        AppLog(source: "fresh", sinks: [NDJSONFileSink(source: "fresh", directory: nested)]).info("m")
        #expect(try records(in: nested, source: "fresh").map(\.message) == ["m"])
    }

    /// And concurrent emits do not interleave inside a record. The sink
    /// serialises on its own queue; without that, two writes could split
    /// each other's bytes and no line would parse.
    @Test func concurrentEmitsProduceWholeRecords() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AppLog(source: "race", sinks: [NDJSONFileSink(source: "race", directory: dir)])
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<120 { group.addTask { log.info("message number \(i)") } }
        }
        let decoded = try records(in: dir, source: "race")
        #expect(decoded.count == 120, "\(decoded.count) records survived of 120")
        #expect(Set(decoded.map(\.message)).count == 120, "records were lost or duplicated")
    }
}
