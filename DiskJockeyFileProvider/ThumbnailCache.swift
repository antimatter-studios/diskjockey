//
// ThumbnailCache.swift — SQLite-backed cache for thumbnail bytes the
// Go driver fetched for a `(mount, path, size)` tuple.
//
// Why a cache:
//
//   • Finder calls `fetchThumbnailsForItemIdentifiers` repeatedly —
//     once when a folder opens, again when the user scrolls back in,
//     again when icon size changes, again when an enumerator
//     restarts. Without a cache every one of those round-trips hits
//     the provider's HTTP API for the same JPEG.
//   • We're paying a 4–20 KB JPEG download per file per fetch. A
//     200-photo folder visited a few times rapidly burns through a
//     metered connection; with a cache, we pay that once per file
//     per TTL window.
//
// Why SQLite (vs in-memory NSCache):
//
//   • The FileProvider extension is short-lived — fileproviderd may
//     respawn it minutes later, or after a sleep/wake. An in-memory
//     cache is gone by then. Persisting on disk lets the next spawn
//     reuse the bytes for free.
//   • Storage cost is bounded by the TTL (5 min) and we periodically
//     vacuum stale rows on every write — a few hundred KB at most.
//
// Key shape: (mount_id, path, size_bucket). We round the requested
// size up to 64 / 128 / 256 / 512 buckets so a Finder request for
// 96px and one for 100px hit the same cache row.
//
// Thread safety: all access goes through a single serial queue. The
// underlying sqlite3 handle is opened with `SQLITE_OPEN_FULLMUTEX`
// for belt-and-braces in case a future caller bypasses the queue.
//

import DiskJockeyLibrary
import Foundation
import SQLite3

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    /// Long enough to absorb repeated scroll-into-folder round-trips,
    /// short enough that an updated thumbnail surfaces within the same
    /// coffee break.
    private static let ttlSeconds: TimeInterval = 5 * 60

    private let queue = DispatchQueue(label: "com.antimatterstudios.diskjockey.thumbcache")
    private var db: OpaquePointer?
    private let dbURL: URL

    private init() {
        let group = AppLog.groupIdentifier
        let fm = FileManager.default
        let containerURL = fm.containerURL(
            forSecurityApplicationGroupIdentifier: group
        )
        let cacheDir = (containerURL ?? fm.temporaryDirectory)
            .appendingPathComponent("Caches", isDirectory: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.dbURL = cacheDir.appendingPathComponent("thumbnails.sqlite")

        queue.sync { openAndPrepare() }
    }

    // MARK: - Public

    /// Look up a cached thumbnail; returns `nil` if absent or expired.
    /// Expired rows are deleted lazily on the next `put` for that key.
    func get(mountID: String, path: String, sizePx: Int) -> Data? {
        let bucket = Self.bucket(for: sizePx)
        return queue.sync { fetch(mountID: mountID, path: path, bucket: bucket) }
    }

    /// Insert / replace the cached thumbnail. Also vacuums any rows
    /// older than the TTL — bounded work per write keeps the table
    /// small without a separate maintenance task.
    func put(mountID: String, path: String, sizePx: Int, data: Data) {
        let bucket = Self.bucket(for: sizePx)
        queue.sync { upsert(mountID: mountID, path: path, bucket: bucket, data: data) }
    }

    // MARK: - Internals

    private func openAndPrepare() {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dbURL.path, &db, flags, nil)
        if rc != SQLITE_OK {
            log.error("ThumbnailCache: sqlite3_open_v2 failed rc=\(rc) path=\(dbURL.path)")
            db = nil
            return
        }
        // Schema: (mount_id, path, size_bucket) is the lookup key;
        // fetched_at is unix epoch seconds (REAL); data is the JPEG
        // bytes. WITHOUT ROWID keeps the storage layout tight for a
        // table where every row is keyed by the composite primary key.
        let schema = """
        CREATE TABLE IF NOT EXISTS thumbnails (
            mount_id     TEXT    NOT NULL,
            path         TEXT    NOT NULL,
            size_bucket  INTEGER NOT NULL,
            fetched_at   REAL    NOT NULL,
            data         BLOB    NOT NULL,
            PRIMARY KEY (mount_id, path, size_bucket)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS thumbnails_age ON thumbnails(fetched_at);
        """
        var errmsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, schema, nil, nil, &errmsg) != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? "(unknown)"
            log.error("ThumbnailCache: schema create failed: \(msg)")
            sqlite3_free(errmsg)
        }
    }

    private func fetch(mountID: String, path: String, bucket: Int) -> Data? {
        guard let db = db else { return nil }
        let cutoff = Date().timeIntervalSince1970 - Self.ttlSeconds
        let sql = "SELECT data FROM thumbnails WHERE mount_id = ? AND path = ? AND size_bucket = ? AND fetched_at >= ?"
        guard let stmt = prepareStatement(db, sql: sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindThumbnailKey(stmt, mountID: mountID, path: path, bucket: bucket, cutoff: cutoff)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readBlob(from: stmt, column: 0)
    }

    private func prepareStatement(_ db: OpaquePointer, sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    private func bindThumbnailKey(_ stmt: OpaquePointer,
                                  mountID: String, path: String, bucket: Int, cutoff: Double) {
        sqlite3_bind_text(stmt, 1, mountID, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, path, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(bucket))
        sqlite3_bind_double(stmt, 4, cutoff)
    }

    private func readBlob(from stmt: OpaquePointer, column: Int32) -> Data? {
        let bytes = sqlite3_column_blob(stmt, column)
        let count = Int(sqlite3_column_bytes(stmt, column))
        guard let bytes, count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private func upsert(mountID: String, path: String, bucket: Int, data: Data) {
        guard let db = db else { return }
        let now = Date().timeIntervalSince1970

        // Vacuum stale rows first — bounded work, keeps the table
        // size proportional to "files currently being browsed."
        let cutoff = now - Self.ttlSeconds
        var vacStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM thumbnails WHERE fetched_at < ?", -1, &vacStmt, nil) == SQLITE_OK {
            sqlite3_bind_double(vacStmt, 1, cutoff)
            sqlite3_step(vacStmt)
        }
        sqlite3_finalize(vacStmt)

        let sql = """
        INSERT OR REPLACE INTO thumbnails
            (mount_id, path, size_bucket, fetched_at, data)
        VALUES (?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, mountID, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, path, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(bucket))
        sqlite3_bind_double(stmt, 4, now)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress
            sqlite3_bind_blob(stmt, 5, base, Int32(data.count), Self.SQLITE_TRANSIENT)
        }
        sqlite3_step(stmt)
    }

    /// Pick the smallest provider-friendly bucket >= the requested
    /// size, so close-but-different requests share a cache row.
    /// Mirrors the buckets the Go driver maps to Dropbox's
    /// thumbnail size enum.
    private static func bucket(for sizePx: Int) -> Int {
        let buckets = [32, 64, 128, 256, 480, 640, 960, 1024, 2048]
        for b in buckets where b >= sizePx { return b }
        return buckets.last!
    }

    /// `SQLITE_TRANSIENT` from the C macro — sqlite copies the value
    /// before stepping, so we don't have to keep our Swift String /
    /// Data alive across the bind. The bridging header doesn't
    /// expose the macro, so we materialise it the same way the
    /// SQLite source does.
    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )
}
