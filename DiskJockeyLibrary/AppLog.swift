//
// AppLog.swift — single logging surface for the host app and every
// sandboxed helper (FSKit extensions, FileProvider, XPC service, future
// Rust/Go backends).
//
// One call site, N sinks. Configure sinks at init (or mutate at runtime)
// without changing any call site. Built-in sinks:
//
//   - NDJSONFileSink   → writes to a .ndjson file in the shared app-group
//                         container; tailed by the host app's
//                         LogTailService and surfaced in the UI Logs panel.
//   - OSLogSink        → mirrors to os_log under subsystem
//                         "com.antimatterstudios.diskjockey" (category =
//                         source), so `log stream`, Console.app, and
//                         sysdiagnose captures stay intact.
//   - StdoutSink       → plain text to stderr — useful for CLI-style
//                         subprocesses (Go backend, tools) where the host
//                         pipes stdio.
//
// Backends outside Swift (Rust, Go) can produce the same NDJSON wire format
// with plain file I/O — no Apple-specific APIs needed on the emit side.
//

import Foundation
import os

public enum AppLogLevel: String, Codable {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

public struct AppLogLine: Codable {
    public let ts: String
    public let level: String
    public let source: String
    public let message: String
    public let pid: Int32
    /// Structured event identifier (e.g. "fsck.start", "fsck.progress").
    /// nil for plain text log lines. Consumers use it to route events to
    /// per-subject state (e.g. per-volume status) in addition to the flat
    /// log stream.
    public let kind: String?
    /// Free-form key/value payload accompanying a structured event.
    /// Keys are application-defined (e.g. "bsd", "phase", "done", "total").
    /// Values are always stringified at the boundary so the wire format
    /// stays simple; consumers coerce back to whatever type they need.
    public let fields: [String: String]?
    /// Coarse routing tag. Drives which UI panels (system Logs view,
    /// per-mount detail log) display the line — each panel keeps its
    /// own denylist of scopes. Canonical values: "lifecycle", "probe",
    /// "fsck", "volume", "enumerate", "io", "stats". `nil` means
    /// untagged → visible in every panel.
    public let scope: String?

    public init(level: AppLogLevel, source: String, message: String,
                kind: String? = nil, fields: [String: String]? = nil,
                scope: String? = nil) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.ts = f.string(from: Date())
        self.level = level.rawValue
        self.source = source
        self.message = message
        self.pid = ProcessInfo.processInfo.processIdentifier
        self.kind = kind
        self.fields = fields
        self.scope = scope
    }
}

/// Canonical scope values. Centralised so both emitters and consumers
/// (LogRepository denylist, scope-toggle UI, per-mount filter) reference
/// the same strings. Untagged messages (scope=nil) bypass all denylists.
public enum AppLogScope {
    /// Mount / unmount / activate / deactivate / app launch+shutdown /
    /// attach+detach. The "things happened" backbone of the system log.
    public static let lifecycle = "lifecycle"
    /// Disk detection — probe success/failure, magic-number checks.
    public static let probe = "probe"
    /// Filesystem check progress (fsck.start/progress/done/failed).
    public static let fsck = "fsck"
    /// Volume identity events (volume.info / volume.clean / volume.dirty)
    /// emitted once at mount time.
    public static let volume = "volume"
    /// Directory enumeration chatter (enumerateDirectory + per-entry rows,
    /// AppleDouble swallow). High-volume; excluded from system log by
    /// default.
    public static let enumerate = "enumerate"
    /// Block-device read/write/metadata callbacks. High-volume; excluded
    /// from system log by default.
    public static let io = "io"
    /// Periodic IO heartbeats (kind="io.stats"). Excluded from system log
    /// by default.
    public static let stats = "stats"

    /// All canonical scopes, in display order.
    public static let all: [String] = [
        lifecycle, probe, fsck, volume, enumerate, io, stats
    ]
}

/// A sink consumes one log line and emits it somewhere (file, os_log,
/// stdout, network, in-memory ring, etc). Keep it narrow on purpose —
/// anything that wants to receive a log line conforms.
public protocol AppLogSink: AnyObject {
    func emit(_ line: AppLogLine)
}

public final class AppLog: @unchecked Sendable {
    public static let groupIdentifier = "group.com.antimatterstudios.diskjockey"
    public static let logDirName = "Logs"
    public static let subsystem = "com.antimatterstudios.diskjockey"

    public let source: String
    private let lock = NSLock()
    private var sinks: [AppLogSink]

    /// Default app-wide instance — NDJSON file + os_log mirror. Replace
    /// `sinks` via `configure(_:)` to change behavior at runtime.
    public static let shared: AppLog = AppLog(
        source: "app",
        sinks: AppLog.defaultSinks(source: "app")
    )

    public init(source: String, sinks: [AppLogSink]) {
        self.source = source
        self.sinks = sinks
    }

    /// Convenience: the sink stack used by default — NDJSON file in the
    /// shared container + os_log mirror. Most sources want this.
    public static func defaultSinks(source: String) -> [AppLogSink] {
        return [
            NDJSONFileSink(source: source),
            OSLogSink(source: source)
        ]
    }

    /// Swap the active sink list. Useful for tests, CLI builds, or runtime
    /// reconfiguration (e.g. "log to stdout only when DJ_LOG=stdout").
    public func configure(_ sinks: [AppLogSink]) {
        lock.lock(); defer { lock.unlock() }
        self.sinks = sinks
    }

    public func debug(_ message: String, scope: String? = nil) { emit(.debug, message, scope: scope) }
    public func info(_ message: String, scope: String? = nil)  { emit(.info,  message, scope: scope) }
    public func warn(_ message: String, scope: String? = nil)  { emit(.warn,  message, scope: scope) }
    public func error(_ message: String, scope: String? = nil) { emit(.error, message, scope: scope) }

    /// Emit a structured, kind-tagged event. Goes through the same sinks
    /// as plain text — consumers that only care about text see a derived
    /// human-readable message; consumers routing on `kind` get the full
    /// kind + fields. `message` is auto-generated as "kind fields" unless
    /// caller overrides.
    public func event(kind: String, fields: [String: String] = [:],
                      level: AppLogLevel = .info, message: String? = nil,
                      scope: String? = nil) {
        let msg = message ?? Self.formatEvent(kind: kind, fields: fields)
        let line = AppLogLine(level: level, source: source, message: msg,
                              kind: kind, fields: fields, scope: scope)
        lock.lock()
        let snapshot = sinks
        lock.unlock()
        for s in snapshot { s.emit(line) }
    }

    private static func formatEvent(kind: String, fields: [String: String]) -> String {
        if fields.isEmpty { return kind }
        let kv = fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "")" }.joined(separator: " ")
        return "\(kind) \(kv)"
    }

    private func emit(_ level: AppLogLevel, _ message: String, scope: String? = nil) {
        let line = AppLogLine(level: level, source: source, message: message, scope: scope)
        lock.lock()
        let snapshot = sinks
        lock.unlock()
        for s in snapshot { s.emit(line) }
    }
}

// MARK: - TaggedLogger
//
// Thin wrapper around `AppLog` that automatically attaches a fixed
// dictionary of structured fields to every line it emits. Callers
// build one per subject (mount, disk, task) once, then call
// `.info` / `.warn` / `.error` / `.debug` the same way as plain
// AppLog.
//
// The recipient is identical in shape on-wire — every message goes
// out as `kind=<kind>` with `fields[...]` populated — so
// LogTailService + LogRepository keep working without changes.
// What we gain: consumers that want per-mount / per-disk filtering
// can route on `fields["mount"]` or `fields["bsd"]` without every
// call site having to remember to pass those fields.
//
// Example:
//
//     let mlog = TaggedLogger(log,
//         fields: ["mount": domainID], kind: "fileprovider.mount")
//     mlog.info("fetchContents for \(path)")
//     // on-wire: {"kind":"fileprovider.mount","fields":{"mount":"UUID"},
//     //           "level":"INFO","message":"fetchContents for /foo.txt",…}

public final class TaggedLogger {
    public let log: AppLog
    public let fields: [String: String]
    public let kind: String
    /// Default scope applied to every emit unless the caller passes a
    /// per-call override. nil → untagged (visible in every panel).
    public let scope: String?

    public init(_ log: AppLog, fields: [String: String], kind: String,
                scope: String? = nil) {
        self.log = log
        self.fields = fields
        self.kind = kind
        self.scope = scope
    }

    public func info(_ message: String, scope: String? = nil) {
        log.event(kind: kind, fields: fields, level: .info, message: message,
                  scope: scope ?? self.scope)
    }

    public func warn(_ message: String, scope: String? = nil) {
        log.event(kind: kind, fields: fields, level: .warn, message: message,
                  scope: scope ?? self.scope)
    }

    public func error(_ message: String, scope: String? = nil) {
        log.event(kind: kind, fields: fields, level: .error, message: message,
                  scope: scope ?? self.scope)
    }

    public func debug(_ message: String, scope: String? = nil) {
        log.event(kind: kind, fields: fields, level: .debug, message: message,
                  scope: scope ?? self.scope)
    }

    /// Emit a one-off event overriding `kind` and/or merging extra
    /// fields into the logger's defaults. Handy for finer-grained
    /// signals (e.g. `fsck.progress`) from inside a subject-scoped
    /// logger.
    public func event(kind: String? = nil,
                      fields extra: [String: String] = [:],
                      level: AppLogLevel = .info,
                      message: String? = nil,
                      scope: String? = nil) {
        var merged = self.fields
        for (k, v) in extra { merged[k] = v }
        log.event(kind: kind ?? self.kind, fields: merged,
                  level: level, message: message,
                  scope: scope ?? self.scope)
    }
}

// MARK: - Built-in sinks

/// Appends NDJSON lines to `<group-container>/Logs/<source>.ndjson`.
/// Serialises writes on a private queue; safe for concurrent emit calls.
public final class NDJSONFileSink: AppLogSink {
    private let fileURL: URL
    private let handle: FileHandle?
    private let queue: DispatchQueue

    public init(source: String) {
        self.queue = DispatchQueue(label: "com.antimatterstudios.diskjockey.applog.file.\(source)")
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: AppLog.groupIdentifier)
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent(AppLog.logDirName, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("\(source).ndjson")
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        var opened: FileHandle? = nil
        let path = fileURL.path
        let diag = Logger(subsystem: AppLog.subsystem, category: "ndjson")
        do {
            opened = try FileHandle(forWritingTo: fileURL)
            try opened?.seekToEnd()
            diag.info("NDJSONFileSink opened \(source, privacy: .public) fd=\(opened?.fileDescriptor ?? -1) path=\(path, privacy: .public)")
        } catch {
            let err = error.localizedDescription
            diag.error("NDJSONFileSink open failed for \(source, privacy: .public) at \(path, privacy: .public): \(err, privacy: .public)")
            opened = nil
        }
        self.handle = opened
    }

    public func emit(_ line: AppLogLine) {
        guard let handle = handle, let data = try? JSONEncoder().encode(line) else { return }
        let diag = Logger(subsystem: AppLog.subsystem, category: "ndjson")
        // Synchronous write: short-lived extension processes (NTFS in
        // particular — FSKit respawns a fresh extension per resource
        // op) could exit before an async dispatch drained. AppLog's
        // outer lock already serialises callers so we don't need the
        // extra dispatch queue for ordering.
        queue.sync {
            do {
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data("\n".utf8))
            } catch {
                diag.error("NDJSONFileSink write failed fd=\(handle.fileDescriptor): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Mirrors to os_log so existing tooling (`log stream`, Console.app,
/// sysdiagnose) keeps seeing messages with full text (privacy: .public).
public final class OSLogSink: AppLogSink {
    private let logger: Logger

    public init(source: String) {
        self.logger = Logger(subsystem: AppLog.subsystem, category: source)
    }

    public func emit(_ line: AppLogLine) {
        let type: OSLogType
        switch AppLogLevel(rawValue: line.level) ?? .info {
        case .debug:  type = .debug
        case .info:   type = .info
        case .warn:   type = .default
        case .error:  type = .error
        }
        logger.log(level: type, "\(line.message, privacy: .public)")
    }
}

/// Plain-text to stderr. Handy for CLI builds or when stdout/stderr is
/// piped by a parent process (e.g. our Go backend launch-agent config).
public final class StderrSink: AppLogSink {
    public init() {}
    public func emit(_ line: AppLogLine) {
        FileHandle.standardError.write(Data(
            "[\(line.ts)] \(line.level) \(line.source): \(line.message)\n".utf8
        ))
    }
}
