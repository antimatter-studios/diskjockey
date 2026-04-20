//
// FileProviderDirectClient.swift — per-domain handle around FTPDriver.
//
// One instance per NSFileProviderDomain. Owns:
//
//   • the stable Int32 mountID libftp uses as its global-map key
//   • the DirectMountConfig + password pulled from
//     MountConfigStore / MountKeychain at init time
//   • lazy "have we called ftp_mount yet?" state
//
// The FileProvider extension is short-lived (FSKit can respawn it
// between ops), so the Swift-side state here is recreated each spawn.
// That's fine: libftp's global FTPDriver{} map persists as long as
// libftp is loaded into the extension's address space, so a subsequent
// client with the same mountID hops straight back to an already-mounted
// session. We still call `ensureConnected()` before every op in case
// libftp was freshly loaded (e.g. after a true process restart).
//
// On a transient failure the client drops its "mounted" flag and the
// next op re-mounts. Kept dumb — no retry loops, no exponential backoff.
// Those belong higher up the stack.
//

import Foundation
import FileProvider
import DiskJockeyLibrary

/// Errors the direct client raises to the extension layer.
enum FileProviderDirectClientError: Error, CustomStringConvertible {
    case missingPassword(domainID: String, underlying: Error)
    case missingConfig(domainID: String, underlying: Error)
    case driver(FTPDriverError)

    var description: String {
        switch self {
        case .missingPassword(let d, let e):
            return "direct-client: keychain load failed for domain \(d): \(e)"
        case .missingConfig(let d, let e):
            return "direct-client: config load failed for domain \(d): \(e)"
        case .driver(let e):
            return "direct-client: driver error: \(e)"
        }
    }
}

final class FileProviderDirectClient {
    /// Human-readable domain identifier (what NSFileProviderDomain
    /// carries). Kept for diagnostics only; libftp keys by `libftpID`.
    let domainID: String

    /// The Int32 libftp uses as its map key. Derived deterministically
    /// from `domainID` — see `Self.libftpID(for:)`. Using a hash keeps
    /// the domainID → Int mapping stable across extension respawns.
    let libftpID: Int32

    let config: DirectMountConfig
    private let password: String

    /// Per-mount logger — carries `fields["mount"]=<domainID>` on every
    /// line. The FileProvider extension instantiates one per domain
    /// and hands it in here so both sides log against the same tag.
    private let mlog: TaggedLogger

    /// Swift-side "we've called ftp_mount successfully this process" flag.
    /// Not authoritative — libftp is the source of truth — but lets us
    /// skip repeat mount calls on the happy path.
    private var mounted = false
    private let lock = NSLock()

    /// Build a client by loading the plist + keychain entry for this
    /// domainID. Throws if either read fails; callers should fall back
    /// to XPC on any error.
    init(domainID: String,
         log: TaggedLogger,
         store: MountConfigStore = MountConfigStore(),
         keychain: MountKeychain = MountKeychain()) throws {
        self.domainID = domainID
        self.libftpID = Self.libftpID(for: domainID)
        self.mlog = log
        do {
            self.config = try store.load(domainID: domainID)
        } catch {
            throw FileProviderDirectClientError.missingConfig(
                domainID: domainID, underlying: error
            )
        }
        do {
            self.password = try keychain.load(domainID: domainID)
        } catch {
            throw FileProviderDirectClientError.missingPassword(
                domainID: domainID, underlying: error
            )
        }
    }

    // MARK: - Lazy mount

    /// Idempotent: first call runs `ftp_mount`, later calls are no-ops
    /// unless a prior op reset `mounted` (reconnect path).
    private func ensureConnected() throws {
        lock.lock()
        defer { lock.unlock() }
        if mounted { return }
        do {
            try FTPDriver.connect(mountID: libftpID,
                                  config: config,
                                  password: password)
            mounted = true
        } catch let e as FTPDriverError {
            throw FileProviderDirectClientError.driver(e)
        }
    }

    /// Call after any error that looks like a connection drop; the
    /// next op will transparently re-mount.
    private func markDisconnected() {
        lock.lock()
        mounted = false
        lock.unlock()
    }

    // MARK: - Ops (all synchronous; libftp is already blocking under
    //        the hood, and FileProvider callbacks can come in on any
    //        queue — we don't add our own threading).

    func stat(path: String) throws -> RemoteFileInfo {
        try ensureConnected()
        do {
            return try FTPDriver.stat(mountID: libftpID, path: path)
        } catch let e as FTPDriverError {
            if case .operationFailed = e { /* fine — data-layer error */ }
            else { markDisconnected() }
            throw FileProviderDirectClientError.driver(e)
        }
    }

    func listDir(path: String) throws -> [RemoteFileInfo] {
        try ensureConnected()
        do {
            return try FTPDriver.listDir(mountID: libftpID, path: path)
        } catch let e as FTPDriverError {
            if case .operationFailed = e { /* data-layer, keep session */ }
            else { markDisconnected() }
            throw FileProviderDirectClientError.driver(e)
        }
    }

    /// Download `path` into a freshly-created file under the extension's
    /// working directory. Returns the URL of the temp file.
    func fetchFile(path: String) throws -> URL {
        try ensureConnected()
        let url = workingFileURL()
        do {
            try FTPDriver.fetchFile(mountID: libftpID, path: path, to: url)
            return url
        } catch let e as FTPDriverError {
            // Treat read failures as session-fatal only if the code is
            // non-data. Today libftp doesn't distinguish — be safe.
            if case .readFailed = e { markDisconnected() }
            throw FileProviderDirectClientError.driver(e)
        }
    }

    func disconnect() {
        lock.lock()
        let wasMounted = mounted
        mounted = false
        lock.unlock()
        guard wasMounted else { return }
        do { try FTPDriver.disconnect(mountID: libftpID) }
        catch { mlog.error("disconnect error: \(error)") }
    }

    // MARK: - Helpers

    /// FileProvider extensions get a sandboxed temporary directory via
    /// `FileManager.temporaryDirectory` that's writable without extra
    /// entitlement. We use that for fetched file contents; the FP
    /// framework copies the bytes into its own storage before returning
    /// to Finder, so retention here is short.
    private func workingFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    }

    /// Map a domainID string → stable, nonzero Int32 libftp mountID.
    ///
    /// We hash with FNV-1a 32-bit (folded into positive 31 bits) so the
    /// result is:
    ///   • deterministic (same domain → same id across respawns)
    ///   • fits in Int32 (libftp signature is `C.int`)
    ///   • never zero (libftp uses zero as "no mount" sentinel in some
    ///     drivers — avoid by biasing to at least 1)
    ///   • never negative (sign bit clear; keeps the id readable in
    ///     logs)
    ///
    /// Collisions between two unrelated domainIDs remain theoretically
    /// possible — if it ever happens in the wild, layer on a second
    /// step that opens mountID + 1, +2, … and tracks assignments in a
    /// static table. Not worth the complexity until we see it.
    static func libftpID(for domainID: String) -> Int32 {
        var hash: UInt32 = 0x811C9DC5        // FNV offset basis (32-bit)
        for byte in domainID.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193         // FNV prime (32-bit)
        }
        // Clear sign bit so we always land in [0, Int32.max].
        let positive = Int32(hash & 0x7FFFFFFF)
        return positive == 0 ? 1 : positive
    }
}
