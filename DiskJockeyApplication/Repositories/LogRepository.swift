import Foundation
import Combine
import DiskJockeyLibrary

/// In-memory log store. Lines flow in from `LogTailService` (which
/// tails the NDJSON files subprocesses write) via `addLogEntry(_:)`;
/// the Logs view observes `$logs` for live updates.
///
/// No backend coupling — every subprocess writes its own ndjson under
/// the shared app-group container; `LogTailService` is the only writer.
///
/// Filtering: every entry carries an optional `scope` (carried over from
/// `AppLogLine.scope`). The system Logs panel reads `visibleLogs`, which
/// drops entries whose scope is in `suppressedScopes`. The full `logs`
/// array still holds everything, so toggling a scope back on at runtime
/// reveals the entries that were already received but hidden.
public final class LogRepository: ObservableObject {
    @Published public private(set) var logs: [LogEntry] = []
    @Published public private(set) var isLoading = false

    /// Scopes the system log panel hides by default. The high-volume
    /// per-mount chatter — directory enumeration, block-device callbacks,
    /// periodic IO heartbeats — would otherwise drown out app-level
    /// lifecycle/probe/fsck events. UI offers toggles to add/remove.
    /// Persisted across launches via @AppStorage in the view layer; the
    /// view writes back into this property.
    @Published public var suppressedScopes: Set<String> = [
        "enumerate", "io", "stats"
    ]

    private let maxLogEntries = 1000

    public init() {}

    public func logsPublisher() -> AnyPublisher<[LogEntry], Never> {
        $logs.eraseToAnyPublisher()
    }

    /// Logs minus entries whose scope is in `suppressedScopes`. Untagged
    /// entries (scope == nil) are always visible.
    public var visibleLogs: [LogEntry] {
        let suppressed = suppressedScopes
        if suppressed.isEmpty { return logs }
        return logs.filter { entry in
            guard let scope = entry.scope else { return true }
            return !suppressed.contains(scope)
        }
    }

    public func addLogEntry(_ entry: LogEntry) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.logs.insert(entry, at: 0)
            if self.logs.count > self.maxLogEntries {
                self.logs = Array(self.logs.prefix(self.maxLogEntries))
            }
        }
    }

    public func clearLogs() {
        DispatchQueue.main.async { [weak self] in
            self?.logs = []
        }
    }

    public func exportLogs() {
        let snapshot = Array(self.logs.prefix(self.maxLogEntries))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("logs.txt")
        try? snapshot.map { $0.message }
            .joined(separator: "\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
