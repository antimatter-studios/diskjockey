import Foundation
import Combine
import DiskJockeyLibrary

public struct AppLogMessage: Identifiable {
    public let id = UUID()
    public let message: String
    public let category: String
    public let timestamp: Date
}

public protocol AppLogger: AnyObject {
    func log(_ msg: String, category: String)
    func log(_ msg: String)
}

/// Thin view-model over `LogRepository`. Republishes a *filtered* view
/// of the repository's logs to SwiftUI: entries whose `scope` is in
/// `suppressedScopes` are dropped on the way to `messages`. The full
/// repository contents stay intact, so toggling a scope back on instantly
/// surfaces every previously-hidden entry that's still in memory.
public class AppLogModel: ObservableObject {
    @Published public var messages: [LogEntry] = []
    /// Two-way bound to `LogRepository.suppressedScopes`. The view writes
    /// this (e.g. via a Toggle); the change is mirrored to the repo so
    /// any other observer of the same repo (today: just this view-model;
    /// tomorrow: an export filter, a unit test) stays in sync.
    @Published public var suppressedScopes: Set<String> = []
    private var cancellables = Set<AnyCancellable>()
    private let logRepository: LogRepository

    public init(logRepository: LogRepository) {
        self.logRepository = logRepository
        self.suppressedScopes = logRepository.suppressedScopes

        Publishers.CombineLatest(
            logRepository.$logs,
            logRepository.$suppressedScopes
        )
        .map { logs, suppressed -> [LogEntry] in
            if suppressed.isEmpty { return logs }
            return logs.filter { entry in
                guard let scope = entry.scope else { return true }
                return !suppressed.contains(scope)
            }
        }
        .receive(on: DispatchQueue.main)
        .assign(to: &$messages)

        // Mirror local edits back into the repo. `dropFirst` skips the
        // initial assignment from the line above so we don't bounce.
        self.$suppressedScopes
            .dropFirst()
            .sink { [weak logRepository] new in
                logRepository?.suppressedScopes = new
            }
            .store(in: &cancellables)
    }

    public func clearLogs() {
        logRepository.clearLogs()
    }

    public func exportLogs() {
        logRepository.exportLogs()
    }
}
