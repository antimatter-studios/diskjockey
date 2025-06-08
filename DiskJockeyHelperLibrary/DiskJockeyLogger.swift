import Foundation
import os.log

public class DiskJockeyLogger {
    public static var isEnabled: Bool = true // In future: make this user-configurable
    public static let log = OSLog(subsystem: "com.diskjockey.helper", category: "DiskJockey")
    
    public static func debug(_ msg: String) {
        guard isEnabled else { return }
        os_log("%{public}@", log: log, type: .debug, msg)
    }
    public static func info(_ msg: String) {
        guard isEnabled else { return }
        os_log("%{public}@", log: log, type: .info, msg)
    }
    public static func error(_ msg: String) {
        guard isEnabled else { return }
        os_log("%{public}@", log: log, type: .error, msg)
    }
}
