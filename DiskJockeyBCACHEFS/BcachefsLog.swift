/*
 * BcachefsLog.swift — the extension's logging surface, in a file of its own
 * so it builds with the volume in DiskJockeyBCACHEFSCore, as XfsLog.swift
 * does for DiskJockeyXFSCore.
 *
 * MIT License — see LICENSE
 */

import Foundation
import DiskJockeyLibrary

/// Single logging surface — fans out to os_log + NDJSON file via AppLog.
let log = AppLog(source: "bcachefs", sinks: AppLog.defaultSinks(source: "bcachefs"))
