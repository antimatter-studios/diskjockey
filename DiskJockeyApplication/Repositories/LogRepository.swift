import Foundation
import Combine
import DiskJockeyLibrary

/// In-memory log store. Lines flow in from `LogTailService` (which
/// tails the NDJSON files subprocesses write) via `addLogEntry(_:)`;
/// the Logs view observes `$logs` for live updates.
///
/// No backend coupling — every subprocess writes its own ndjson under
/// the shared app-group container; `LogTailService` is the only writer.
public final class LogRepository: ObservableObject {
    @Published public private(set) var logs: [LogEntry] = []
    @Published public private(set) var isLoading = false

    private let maxLogEntries = 1000

    public init() {}

    public func logsPublisher() -> AnyPublisher<[LogEntry], Never> {
        $logs.eraseToAnyPublisher()
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
