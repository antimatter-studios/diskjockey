import Foundation
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

import Combine

public class AppLogModel: ObservableObject {
    @Published public var messages: [LogEntry] = []
    private var cancellables = Set<AnyCancellable>()
    private let logRepository: LogRepository

    public init(logRepository: LogRepository) {
        self.logRepository = logRepository
        self.logRepository.logsPublisher()
            .receive(on: DispatchQueue.main)
            .assign(to: &$messages)
    }

    public func clearLogs() {
        logRepository.clearLogs()
    }
    
    public func refreshLogs() {
        Task {
            await logRepository.refresh()
        }
    }
    
    public func exportLogs() {
        logRepository.exportLogs()
    }
}
