/*
 * NTFSLog.swift — the extension's logging surface, in a file of its own.
 *
 * It was a file-scope `let` at the top of NTFSFileSystem.swift, which made
 * the volume, whose only use of that file beyond NTFSContainerKind was this
 * global, inseparable from the appex's principal class. Here it builds with
 * the volume in DiskJockeyNTFSCore, as XfsLog.swift does for
 * DiskJockeyXFSCore.
 *
 * MIT License — see LICENSE
 */

import Foundation
import DiskJockeyLibrary

/// Single logging surface — fans out to os_log + NDJSON file (tailed
/// by host app UI) via AppLog's configured sinks.
let log = AppLog(source: "ntfs", sinks: AppLog.defaultSinks(source: "ntfs"))
