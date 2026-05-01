//
// LogTailService.swift — watches the shared log directory, parses NDJSON
// entries written by any subprocess (FSKit extensions, FileProvider, XPC
// service, Go backend), and pushes them into the host-side LogRepository
// so they render in the UI Logs panel.
//
// Pairs with `AppLog` (in DiskJockeyShared/AppLog.swift). Subprocesses write;
// this service reads. Subprocesses don't need any Apple logging APIs —
// they just append JSON lines to a file.
//

import Foundation
import DiskJockeyLibrary

@MainActor
final class LogTailService {
    private let logRepository: LogRepository
    private let logDir: URL
    private var tails: [URL: FileTail] = [:]
    private var dirSource: DispatchSourceFileSystemObject?

    /// Optional subscriber that receives kind-tagged structured events.
    /// Plain log lines (no `kind`) always flow to `logRepository` only;
    /// structured events flow to BOTH the repository (for the flat log
    /// panel) AND to this handler (for per-subject routing, e.g. fsck
    /// progress → AttachedDisksModel).
    var onEvent: ((String, [String: String]) -> Void)?

    /// Optional subscriber that receives every parsed log line. Used
    /// by AttachedDisksModel to populate per-partition logs when a
    /// `bsd` can be resolved from the line (either via structured
    /// fields, or parsed out of the plain-text message).
    var onLine: ((ParsedLogLine) -> Void)?

    init(logRepository: LogRepository) {
        self.logRepository = logRepository
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: AppLog.groupIdentifier)
            ?? fm.temporaryDirectory
        self.logDir = base.appendingPathComponent(AppLog.logDirName, isDirectory: true)
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
    }

    func start() {
        rescan()
        watchDir()
    }

    private func watchDir() {
        let fd = open(logDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename],
            queue: .main
        )
        src.setEventHandler { [weak self] in self?.rescan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        self.dirSource = src
    }

    private func rescan() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: logDir, includingPropertiesForKeys: nil
        ) else { return }
        for url in entries where url.pathExtension == "ndjson" {
            if tails[url] == nil {
                let tail = FileTail(url: url, onLine: { [weak self] line in
                    self?.handleLine(line, fileURL: url)
                })
                tails[url] = tail
                tail.start()
            }
        }
    }

    private func handleLine(_ line: String, fileURL: URL) {
        guard let data = line.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AppLogLine.self, from: data)
        else { return }
        let ts = parseISO8601(payload.ts) ?? Date()
        let entry = LogEntry(
            message: payload.message,
            category: payload.level.lowercased(),
            timestamp: ts,
            source: payload.source,
            metadata: ["pid": String(payload.pid)],
            scope: payload.scope
        )
        let parsed = ParsedLogLine(
            timestamp: ts,
            level: payload.level,
            source: payload.source,
            message: payload.message,
            bsd: Self.resolveBsd(fields: payload.fields, message: payload.message),
            mount: payload.fields?["mount"],
            scope: payload.scope
        )
        Task { @MainActor in
            self.logRepository.addLogEntry(entry)
            self.onLine?(parsed)
            if let kind = payload.kind {
                self.onEvent?(kind, payload.fields ?? [:])
            }
        }
    }

    /// Find the BSD device this line is talking about. Preferred
    /// source is `fields["bsd"]` (set by all structured events).
    /// Falls back to scanning the plain-text message for common
    /// patterns like "diskN" or "disk called" — extensions emit
    /// lots of plain-text lines like "probe disk5: ..." that
    /// should also show up in the per-partition log.
    private static func resolveBsd(fields: [String: String]?, message: String) -> String? {
        if let bsd = fields?["bsd"] { return bsd }
        // "probe disk5: blockSize=..." / "loadResource disk5: ..."
        // Grab the first "disk<digits>(s<digits>)?" token.
        let pattern = #"\bdisk\d+(?:s\d+)?\b"#
        if let range = message.range(of: pattern, options: .regularExpression) {
            return String(message[range])
        }
        return nil
    }

    private func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

/// Tails a single file — reads existing contents on start, then follows
/// appends via dispatch file-system source.
private final class FileTail {
    let url: URL
    let onLine: (String) -> Void
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var buffer = Data()

    init(url: URL, onLine: @escaping (String) -> Void) {
        self.url = url
        self.onLine = onLine
    }

    func start() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        // Skip the existing file contents — on launch the ndjson file
        // contains every event from every prior session of every
        // extension (ext4/ntfs can accumulate tens of MB of events
        // across mount / unmount / fsck cycles). Replaying all of
        // that on the main thread would freeze the app at the
        // bouncing dock icon for long enough that it looks hung.
        // The historical log is still on disk for forensics; this
        // just means the in-app Logs panel starts empty and fills
        // as new events arrive during this session.
        try? handle.seekToEnd()
        self.fileHandle = handle
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.write, .extend],
            queue: .main
        )
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.resume()
        self.source = src
    }

    private func readAvailable() {
        guard let handle = fileHandle else { return }
        let data = handle.availableData
        guard !data.isEmpty else { return }
        buffer.append(data)
        // Single forward pass emitting complete lines. The earlier
        // `buffer.removeSubrange(0...nl)` on each iteration was O(n)
        // per line — a burst of K lines in an M-byte buffer was
        // O(M·K) memmove which pegged the main thread at 100% CPU.
        var cursor = buffer.startIndex
        while let nl = buffer[cursor...].firstIndex(of: 0x0A) {
            if nl > cursor,
               let line = String(data: buffer[cursor..<nl], encoding: .utf8),
               !line.isEmpty {
                onLine(line)
            }
            cursor = buffer.index(after: nl)
        }
        if cursor == buffer.endIndex {
            buffer.removeAll(keepingCapacity: true)
        } else if cursor > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<cursor)
        }
    }
}
