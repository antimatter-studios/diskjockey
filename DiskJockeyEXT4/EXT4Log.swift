//
// EXT4Log.swift — the extension's logging surface, in a file of its own.
//
// This was a file-scope `let` at the top of EXT4FileSystem.swift. It moved
// here so that code which only needs to LOG does not also need the
// principal class: `EXT4Volume.swift` uses `log` eighteen times and
// referenced nothing else from that file except one watchdog call, so
// leaving the global there made 903 lines of volume implementation
// inseparable from the appex's entry point.
//
// The failure mode was memorable, too. Swift does not report an unresolved
// `log` here — `log` also names the C math function, so every `log.info(…)`
// compiled as a member lookup on a function reference and produced
// "reference to member 'info' cannot be resolved without a contextual
// type", 36 times, naming neither the global nor the file it lives in.
//

import Foundation
import DiskJockeyLibrary

/// Single logging surface — fans out to os_log (system) + NDJSON file
/// (tailed by host app UI) via AppLog's configured sinks.
let log = AppLog(source: "ext4", sinks: AppLog.defaultSinks(source: "ext4"))
