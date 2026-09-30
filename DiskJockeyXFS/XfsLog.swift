/*
 * XfsLog.swift — the extension's logging surface, in a file of its own.
 *
 * It was a file-scope `let` at the top of XfsFileSystem.swift, which made
 * the volume, whose only use of that file was this global, inseparable
 * from the appex's principal class. Here it builds with the volume in
 * DiskJockeyXFSCore, as EXT4Log.swift does for DiskJockeyEXT4Core.
 *
 * MIT License — see LICENSE
 */

import Foundation
import DiskJockeyLibrary

/// Single logging surface — fans out to os_log + NDJSON file via AppLog.
let log = AppLog(source: "xfs", sinks: AppLog.defaultSinks(source: "xfs"))
