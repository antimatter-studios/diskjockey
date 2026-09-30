/*
 * SquashfsLog.swift — the extension's logging surface, in a file of its own.
 *
 * It was a file-scope `let` at the top of SquashfsFileSystem.swift, which
 * made the volume, whose only use of that file was this global,
 * inseparable from the appex's principal class. Here it builds with the
 * volume in DiskJockeySQUASHFSCore, as XfsLog.swift does for
 * DiskJockeyXFSCore.
 *
 * MIT License — see LICENSE
 */

import Foundation
import DiskJockeyLibrary

/// Single logging surface — fans out to os_log + NDJSON file via AppLog.
let log = AppLog(source: "squashfs", sinks: AppLog.defaultSinks(source: "squashfs"))
