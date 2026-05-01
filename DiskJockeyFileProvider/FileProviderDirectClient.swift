//
// FileProviderDirectClient.swift — per-domain handle around
// NetworkFSDriver, parameterised by a StoredMountConfig personality.
//
// One instance per NSFileProviderDomain. Owns:
//
//   • the stable Int32 mountID libnetworkfs uses as its MountManager key
//   • the StoredMountConfig + password pulled from MountConfigStore /
//     MountKeychain at init time
//   • lazy "have we called networkfs_mount yet?" state
//
// The FileProvider extension is short-lived (FSKit can respawn it
// between ops), so the Swift-side state here is recreated each spawn.
// That's fine: libnetworkfs's global MountManager persists as long as
// libnetworkfs is loaded into the extension's address space, so a
// subsequent client with the same mountID hops straight back to an
// already-mounted session. We still call `ensureConnected()` before
// every op in case libnetworkfs was freshly loaded (e.g. after a true
// process restart).
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
    case driver(NetworkFSDriverError)

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
    /// carries). Kept for diagnostics only; libnetworkfs keys by `mountID`.
    let domainID: String

    /// The Int32 libnetworkfs uses as its MountManager key. Derived
    /// deterministically from `domainID` — see `Self.mountID(for:)`.
    /// Using a hash keeps the domainID → Int mapping stable across
    /// extension respawns.
    let mountID: Int32

    let config: StoredMountConfig
    /// Protocol-agnostic policy flags (thumbnail toggles etc.).
    /// Loaded alongside the config; `MountPolicy.default` if no
    /// policy file exists for this mount (legacy upgrade path).
    let policy: MountPolicy
    private let password: String

    /// Per-mount logger — carries `fields["mount"]=<domainID>` on every
    /// line. The FileProvider extension instantiates one per domain
    /// and hands it in here so both sides log against the same tag.
    private let mlog: TaggedLogger

    /// Swift-side "we've called networkfs_mount successfully this
    /// process" flag. Not authoritative — libnetworkfs is the source
    /// of truth — but lets us skip repeat mount calls on the happy path.
    private var mounted = false
    private let lock = NSLock()

    /// Build a client by loading the plist + keychain entry for this
    /// domainID. Throws if either read fails; callers should fall back
    /// to XPC on any error.
    init(domainID: String,
         log: TaggedLogger,
         store: MountConfigStore = MountConfigStore(),
         policyStore: MountPolicyStore = MountPolicyStore(),
         keychain: MountKeychain = MountKeychain()) throws {
        self.domainID = domainID
        self.mountID = Self.mountID(for: domainID)
        self.mlog = log
        do {
            self.config = try store.load(domainID: domainID)
        } catch {
            throw FileProviderDirectClientError.missingConfig(
                domainID: domainID, underlying: error
            )
        }
        // Policy is best-effort: a corrupt or unreadable policy file
        // shouldn't take down the whole mount, since the defaults
        // ("everything on") are the same behaviour as before policies
        // existed. Log and proceed with defaults.
        do {
            self.policy = try policyStore.load(domainID: domainID)
        } catch {
            log.warn("policy load failed; using defaults: \(error)")
            self.policy = .default
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

    /// Idempotent: first call runs `networkfs_mount`, later calls are
    /// no-ops unless a prior op reset `mounted` (reconnect path).
    private func ensureConnected() throws {
        lock.lock()
        defer { lock.unlock() }
        if mounted { return }
        let json = config.mountJSON(password: password)
        do {
            try NetworkFSDriver.connect(mountID: mountID,
                                        driverType: config.driverType,
                                        configJSON: json)
            mounted = true
            // A fresh (re)connection is the only signal we trust for
            // "the mount is healthy again" — clear any banner the host
            // app is showing from a prior failure. Data-layer success
            // (a stat/listDir returning OK) doesn't fire a clear,
            // because we'd flood the IPC channel; the user dismisses
            // those, or the next failure overwrites them.
            emitMountErrorCleared(mlog: mlog)
        } catch let e as NetworkFSDriverError {
            emitMountError(mlog: mlog, op: "connect", path: nil, error: e)
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


    // MARK: - Ops (all synchronous; libnetworkfs is already blocking
    //        under the hood, and FileProvider callbacks can come in on
    //        any queue — we don't add our own threading).

    func stat(path: String) throws -> RemoteFileInfo {
        try ensureConnected()
        do {
            return try NetworkFSDriver.stat(mountID: mountID, path: path)
        } catch let e as NetworkFSDriverError {
            if case .operationFailed = e { /* fine — data-layer error */ }
            else { markDisconnected() }
            emitMountError(mlog: mlog, op: "stat", path: path, error: e)
            throw FileProviderDirectClientError.driver(e)
        }
    }

    func listDir(path: String) throws -> [RemoteFileInfo] {
        try ensureConnected()
        do {
            return try NetworkFSDriver.listDir(mountID: mountID, path: path)
        } catch let e as NetworkFSDriverError {
            if case .operationFailed = e { /* data-layer, keep session */ }
            else { markDisconnected() }
            emitMountError(mlog: mlog, op: "listDir", path: path, error: e)
            throw FileProviderDirectClientError.driver(e)
        }
    }

    /// Download `path` into a caller-provided URL. The caller is
    /// responsible for picking a location that `fileproviderd` can
    /// read — typically `NSFileProviderManager(for:).temporaryDirectoryURL()`.
    /// We don't pick the URL ourselves because the appropriate temp
    /// dir depends on the NSFileProviderDomain, which the client
    /// doesn't carry.
    func fetchFile(path: String, to url: URL) throws {
        try ensureConnected()
        do {
            try NetworkFSDriver.fetchFile(mountID: mountID, path: path, to: url)
        } catch let e as NetworkFSDriverError {
            // Treat read failures as session-fatal only if the code is
            // non-data. Today libnetworkfs doesn't distinguish — be safe.
            if case .readFailed = e { markDisconnected() }
            emitMountError(mlog: mlog, op: "fetchFile", path: path, error: e)
            throw FileProviderDirectClientError.driver(e)
        }
    }

    // MARK: - Write ops

    func writeFile(path: String, data: Data) throws {
        try ensureConnected()
        do {
            try NetworkFSDriver.writeFile(mountID: mountID, path: path, data: data)
        } catch let e as NetworkFSDriverError {
            if case .operationFailed = e { /* data-layer, keep session */ }
            else { markDisconnected() }
            emitMountError(mlog: mlog, op: "writefile", path: path, error: e)
            throw FileProviderDirectClientError.driver(e)
        }
    }

    func mkdir(path: String) throws {
        try ensureConnected()
        do {
            try NetworkFSDriver.mkdir(mountID: mountID, path: path)
        } catch let e as NetworkFSDriverError {
            if case .operationFailed = e { /* data-layer, keep session */ }
            else { markDisconnected() }
            emitMountError(mlog: mlog, op: "mkdir", path: path, error: e)
            throw FileProviderDirectClientError.driver(e)
        }
    }

    func removeItem(path: String) throws {
        try ensureConnected()
        do {
            try NetworkFSDriver.removeItem(mountID: mountID, path: path)
        } catch let e as NetworkFSDriverError {
            if case .operationFailed = e { /* data-layer, keep session */ }
            else { markDisconnected() }
            emitMountError(mlog: mlog, op: "remove", path: path, error: e)
            throw FileProviderDirectClientError.driver(e)
        }
    }

    func renameItem(from: String, to: String) throws {
        try ensureConnected()
        do {
            try NetworkFSDriver.renameItem(mountID: mountID, from: from, to: to)
        } catch let e as NetworkFSDriverError {
            if case .operationFailed = e { /* data-layer, keep session */ }
            else { markDisconnected() }
            emitMountError(mlog: mlog, op: "rename", path: from, error: e)
            throw FileProviderDirectClientError.driver(e)
        }
    }

    /// Combined per-mount + network policy: should we fetch
    /// thumbnails right now? Used both by `fetchThumbnails`
    /// (responding to Finder) and by the enumerator's pre-warm path
    /// (so the same toggle + cellular gates apply to both).
    /// Protocol-agnostic — applies to every connector. Drivers
    /// without a Go-side `Thumbnailer` impl will return rc=2 on
    /// the C ABI and we skip silently; the toggle still controls
    /// whether we even try.
    var shouldFetchThumbnails: Bool {
        if !policy.fetchThumbnails { return false }
        if NetworkPathMonitor.shared.isExpensiveOrConstrained {
            return false
        }
        return true
    }

    /// Should the enumerator pre-warm thumbnails for this mount?
    /// Implies `shouldFetchThumbnails` — no point pre-warming a
    /// cache we then refuse to serve. Adds the `backgroundFetch`
    /// gate on top.
    var shouldPrewarmThumbnails: Bool {
        guard shouldFetchThumbnails else { return false }
        return policy.backgroundFetch
    }

    /// Fetch a thumbnail for `path`, sized so the long edge is
    /// approximately `sizePx`. Returns the JPEG bytes the Go driver's
    /// `Thumbnailer` produced. Drivers without thumbnail support
    /// throw `.driver(.thumbnailFailed(code: 2, ...))` — the caller
    /// (FileProviderExtension.fetchThumbnails) treats that as
    /// "skip; let Finder show a generic icon" rather than an error.
    ///
    /// We don't `reportError` here because thumbnail failures are
    /// noise, not a broken-mount signal — every non-image file in a
    /// folder of mixed content would emit a banner. The driver's
    /// real connection errors still surface through ensureConnected.
    func fetchThumbnail(path: String, sizePx: Int) throws -> Data {
        try ensureConnected()
        do {
            return try NetworkFSDriver.fetchThumbnail(
                mountID: mountID, path: path, sizePx: Int32(sizePx)
            )
        } catch let e as NetworkFSDriverError {
            throw FileProviderDirectClientError.driver(e)
        }
    }

    func disconnect() {
        lock.lock()
        let wasMounted = mounted
        mounted = false
        lock.unlock()
        guard wasMounted else { return }
        do { try NetworkFSDriver.disconnect(mountID: mountID) }
        catch { mlog.error("disconnect error: \(error)") }
    }

    // MARK: - Helpers

    /// Map a domainID string → stable, nonzero Int32 mountID for
    /// libnetworkfs's MountManager.
    ///
    /// We hash with FNV-1a 32-bit (folded into positive 31 bits) so the
    /// result is:
    ///   • deterministic (same domain → same id across respawns)
    ///   • fits in Int32 (C-side signature is `C.int`)
    ///   • never zero (MountManager uses zero as "no mount" sentinel in
    ///     some drivers — avoid by biasing to at least 1)
    ///   • never negative (sign bit clear; keeps the id readable in logs)
    ///
    /// Collisions between two unrelated domainIDs remain theoretically
    /// possible — if it ever happens in the wild, layer on a second
    /// step that opens mountID + 1, +2, … and tracks assignments in a
    /// static table. Not worth the complexity until we see it.
    static func mountID(for domainID: String) -> Int32 {
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
