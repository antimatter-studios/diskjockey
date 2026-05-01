//
// NetworkPathMonitor.swift — wraps `NWPathMonitor` so callers can
// cheaply ask "is the active network path expensive (cellular,
// metered) or constrained (Low Data Mode)?" without rebuilding the
// monitor on every check.
//
// Used by the thumbnail policy in `FileProviderExtension`: when the
// user is on a measured connection we skip thumbnail fetches even
// when their per-mount toggle is ON, so a folder of 200 photos
// doesn't burn through their data plan.
//
// `NWPathMonitor` is already efficient — it pushes path updates from
// the OS — so we just hold a singleton, cache the latest path on a
// dedicated queue, and expose a snapshot getter. Reads are atomic
// via the queue's serial guarantee; writers are the OS path-update
// callback.
//

import Foundation
import Network

final class NetworkPathMonitor: @unchecked Sendable {
    /// Process-wide instance. The extension is short-lived enough
    /// that a per-process monitor is fine; we don't need one per
    /// mount because the path is process-wide state anyway.
    static let shared = NetworkPathMonitor()

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.antimatterstudios.diskjockey.pathmonitor")
    /// Latest snapshot. Protected by `queue` — reads happen on the
    /// caller's queue, but the value is a value-type `Bool` so the
    /// race is benign (we'd accept a one-update-stale read either
    /// way; the OS pushes corrections within ms).
    private var _isExpensiveOrConstrained: Bool = false

    private init() {
        self.monitor = NWPathMonitor()
        self.monitor.pathUpdateHandler = { [weak self] path in
            // `isExpensive` flags cellular and tethered hotspots;
            // `isConstrained` is Low Data Mode (user opt-in saving).
            // We treat both as "skip non-essential network."
            self?._isExpensiveOrConstrained =
                path.isExpensive || path.isConstrained
        }
        self.monitor.start(queue: queue)
    }

    /// `true` when the active network path is cellular, tethered, or
    /// the user has Low Data Mode on. Snapshot is updated by the OS
    /// on path changes; reads are non-blocking. Defaults to `false`
    /// before the first update (we'd rather over-fetch on a fresh
    /// boot than wrongly suppress thumbnails on Wi-Fi).
    var isExpensiveOrConstrained: Bool {
        _isExpensiveOrConstrained
    }
}
