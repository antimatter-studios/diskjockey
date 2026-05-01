//
// DirectMountRegistry.swift — owns the lifecycle of "direct" mounts
// (those the host app configures and the FileProvider extension services
// WITHOUT going through the backend TCP server).
//
// Create:
//   1. Allocate a domain UUID.
//   2. Persist StoredMountConfig plist to the app-group container.
//   3. Stash the password in the shared keychain access-group.
//   4. Register an NSFileProviderDomain.
//   5. Query the user-visible URL & drop a ~/DiskJockey/<name> symlink.
//   6. Append an entry to the local registry (UserDefaults).
//
// Remove reverses the above in the opposite order; partial failures log
// but keep going so nothing strands.
//
// Persistence of the registry itself (which mounts exist, their IDs and
// display names) lives in UserDefaults with suite
// `group.com.antimatterstudios.diskjockey` so the host app sees a
// consistent view across launches. The authoritative copy of each
// mount's config still lives in MountConfigStore.
//

import Foundation
import Combine
import FileProvider
import DiskJockeyLibrary

/// A direct mount as tracked by the host app. Lightweight value type;
/// the heavy config is in `MountConfigStore`, the password in the
/// keychain. This is just what the UI needs to render a sidebar row
/// and detail view.
public struct DirectMount: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let displayName: String
    public let config: StoredMountConfig
    public let createdAt: Date
    /// Filename of the symlink actually placed under `~/DiskJockey/`.
    /// May differ from `displayName` if we had to dedupe for a
    /// collision ("Work" → "Work-2").
    public let symlinkName: String

    public init(
        id: UUID = UUID(),
        displayName: String,
        config: StoredMountConfig,
        createdAt: Date = Date(),
        symlinkName: String
    ) {
        self.id = id
        self.displayName = displayName
        self.config = config
        self.createdAt = createdAt
        self.symlinkName = symlinkName
    }

    /// The domain identifier we register with the FileProvider. We use
    /// the UUID string straight — unique, opaque, stable per mount.
    public var domainID: String { id.uuidString }

    // Hashable — id alone is enough (UUIDs are unique across our
    // registry). Spelled out manually because `StoredMountConfig`
    // only conforms to `Equatable`, which blocks the synthesised
    // Hashable derivation.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Most-recent connection / op error for a single direct mount,
/// emitted by the FileProvider extension via `mount.error` events.
/// `summary` is a short one-liner suitable for the banner headline;
/// `detail` carries the raw underlying message for the expand-to-see
/// section. `op` and `path` are diagnostic context.
public struct MountConnectionError: Equatable, Sendable {
    public let summary: String
    public let detail: String
    public let op: String
    public let path: String?
    public let timestamp: Date

    public init(summary: String, detail: String, op: String,
                path: String? = nil, timestamp: Date = Date()) {
        self.summary = summary
        self.detail = detail
        self.op = op
        self.path = path
        self.timestamp = timestamp
    }
}

public enum DirectMountError: Error, LocalizedError {
    case domainRegistrationFailed(underlying: Error)
    case userVisibleURLUnavailable
    case notFound(id: UUID)

    public var errorDescription: String? {
        switch self {
        case .domainRegistrationFailed(let e):
            return "Could not register File Provider domain: \(e.localizedDescription)"
        case .userVisibleURLUnavailable:
            return "File Provider did not return a mount location; the extension may still be starting."
        case .notFound(let id):
            return "Direct mount \(id.uuidString) not found."
        }
    }
}

@MainActor
public final class DirectMountRegistry: ObservableObject {
    /// Observed by the sidebar so it can show direct mounts live.
    @Published public private(set) var mounts: [DirectMount] = []

    /// Per-mount log buffer keyed by domain identifier (same string as
    /// `DirectMount.domainID` / `fields["mount"]` on every
    /// FileProvider-extension log line). Populated by
    /// `applyLogLine(_:)` from the LogTailService pipeline; read by
    /// `DirectMountDetailView` to render a per-mount log strip.
    ///
    /// Capped per mount so a chatty FTP server doesn't blow up memory.
    /// Ordered oldest-first within each bucket — the view renders a
    /// tail slice so scrolling works naturally.
    @Published public private(set) var mountLogs: [String: [AttachedDiskLogLine]] = [:]

    /// Per-mount I/O stats keyed by domain identifier. Populated by
    /// `applyExtensionEvent` whenever an `io.stats` event arrives with
    /// a `mount` field matching one of our domains. Read by
    /// `DirectMountDetailView` to render the throughput sparkline +
    /// totals. Resets on FileProvider extension respawn (counters go
    /// backwards → IOStats.absorb resets the baseline).
    @Published public private(set) var mountStats: [String: IOStats] = [:]

    /// Most-recent connection / op error per domain ID, populated from
    /// `mount.error` events emitted by the FileProvider extension and
    /// cleared on `mount.error.cleared`. Read by `DirectMountDetailView`
    /// to render a banner above the details — empty entry → no banner.
    /// Survives only the host-app process lifetime; on launch the next
    /// failed op repopulates.
    @Published public private(set) var mountErrors: [String: MountConnectionError] = [:]

    private let configStore: MountConfigStore
    private let keychain: MountKeychain
    private let symlinks: SymlinkManager
    private let defaults: UserDefaults

    private static let defaultsKey = "DirectMountRegistry.mounts.v1"
    private static let defaultsSuite = "group.com.antimatterstudios.diskjockey"
    private static let logCap = 500

    public init(
        configStore: MountConfigStore = MountConfigStore(),
        keychain: MountKeychain = MountKeychain(),
        symlinks: SymlinkManager
    ) {
        self.configStore = configStore
        self.keychain = keychain
        self.symlinks = symlinks
        // Shared UserDefaults under the app-group. Falls back to
        // `.standard` if the suite isn't available (tests / tooling).
        self.defaults = UserDefaults(suiteName: Self.defaultsSuite) ?? .standard
        self.mounts = Self.loadPersisted(from: self.defaults)
        AppLog.shared.info("registry init: loaded \(mounts.count) persisted mounts")
        for m in mounts {
            AppLog.shared.info("persisted: id=\(m.domainID) name=\(m.displayName) scheme=\(m.config.scheme.rawValue) at=\(m.config.displayLocation)")
        }
    }

    /// Backfill symlinks for every currently-mounted direct mount.
    /// Called after the user picks a folder for the first time (or
    /// re-picks a new one) so mounts that were registered before the
    /// folder existed get their shortcuts retroactively.
    ///
    /// Idempotent: `createSymlink` replaces an existing link of the
    /// same name, so calling this on a fully-populated folder
    /// refreshes every symlink to its current target URL. Safe to
    /// call more than once.
    public func backfillSymlinks() async {
        AppLog.shared.info("backfillSymlinks start count=\(mounts.count)")
        for mount in mounts {
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(rawValue: mount.domainID),
                displayName: mount.displayName
            )
            guard let manager = NSFileProviderManager(for: domain) else {
                AppLog.shared.info("backfill: no manager for \(mount.displayName); skipping")
                continue
            }
            do {
                let visibleURL = try await userVisibleURL(for: manager)
                _ = try symlinks.createSymlink(name: mount.symlinkName, target: visibleURL)
                AppLog.shared.info("backfill: symlink created for \(mount.displayName) → \(visibleURL.path)")
            } catch {
                AppLog.shared.error("backfill: \(mount.displayName) failed — \(error)")
            }
        }
        AppLog.shared.info("backfillSymlinks done")
    }

    /// Cross-check persisted mounts against NSFileProviderManager's
    /// actual registered domains. Logs mismatches; the UI shows live
    /// mount state via `isMounted(_:)` so we don't need to prune
    /// persistence here — just surface the discrepancy for debugging.
    /// Safe to call multiple times (e.g. on launch + on explicit refresh).
    public func reconcile() async {
        let domains: [NSFileProviderDomain] = await withCheckedContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
                continuation.resume(returning: domains)
            }
        }
        let registeredIDs = Set(domains.map { $0.identifier.rawValue })
        AppLog.shared.info("reconcile: NSFileProviderManager reports \(domains.count) domains")
        for d in domains {
            AppLog.shared.info("registered: id=\(d.identifier.rawValue) displayName=\(d.displayName)")
        }
        for m in mounts {
            let state = registeredIDs.contains(m.domainID) ? "mounted" : "NOT mounted"
            AppLog.shared.info("reconcile: \(m.displayName) (\(m.domainID)) — \(state)")
        }
    }

    // MARK: - Public API

    /// Core create flow — protocol-agnostic. Every per-protocol
    /// convenience method (`createFTPMount`, `createSFTPMount`, …)
    /// builds a `StoredMountConfig` and hands it here. Atomic-ish: we
    /// roll back in reverse if a late step fails.
    public func createMount(
        name: String,
        config: StoredMountConfig,
        password: String
    ) async throws -> DirectMount {
        let id = UUID()
        let domainID = id.uuidString
        let displayName = name.isEmpty ? "\(config.scheme.displayName) Mount" : name
        AppLog.shared.info("createMount START id=\(domainID) scheme=\(config.scheme.rawValue) at=\(config.displayLocation) name=\(displayName)")

        // 1a. Write config plist to the app-group container.
        AppLog.shared.info("step 1a: writing config plist")
        do {
            try configStore.save(config, domainID: domainID)
            AppLog.shared.info("step 1a: config plist saved")
        } catch {
            AppLog.shared.error("step 1a FAILED (config save): \("\(error)")")
            throw error
        }

        // 1b. Stash the secret in the shared keychain access group.
        // For Dropbox this is the OAuth access token (no password);
        // for everything else it's the user-typed password.
        AppLog.shared.info("step 1b: saving secret to shared keychain")
        do {
            try keychain.save(password: password, domainID: domainID)
            AppLog.shared.info("step 1b: secret saved")
        } catch {
            AppLog.shared.error("step 1b FAILED (keychain save): \("\(error)")")
            try? configStore.delete(domainID: domainID)
            throw error
        }

        // 2. Register domain with FileProvider. Pass just the user's
        // chosen name; Finder prepends the provider app name on its own,
        // so any "DiskJockey - " prefix here would render as
        // "DiskJockey - DiskJockey - name".
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: domainID),
            displayName: displayName
        )
        AppLog.shared.info("step 2: NSFileProviderManager.add(domain)")
        do {
            try await NSFileProviderManager.add(domain)
            AppLog.shared.info("step 2: domain registered")
        } catch {
            AppLog.shared.error("step 2 FAILED (domain register): \("\(error)")")
            try? keychain.delete(domainID: domainID)
            try? configStore.delete(domainID: domainID)
            throw DirectMountError.domainRegistrationFailed(underlying: error)
        }

        // 3. Drop a symlink at ~/DiskJockey/<name>. Best-effort — if
        // the sandbox blocks it we still keep the mount. Dedupe name
        // in-process to avoid clobbering an existing link.
        let symlinkName = symlinks.uniqueName(preferred: displayName)
        AppLog.shared.info("step 3: symlink dedupe → \(symlinkName)")
        if let manager = NSFileProviderManager(for: domain) {
            if let visibleURL = try? await userVisibleURL(for: manager) {
                AppLog.shared.info("step 3: user-visible URL = \(visibleURL.path)")
                do {
                    _ = try symlinks.createSymlink(name: symlinkName, target: visibleURL)
                    AppLog.shared.info("step 3: symlink created")
                } catch {
                    AppLog.shared.error("step 3: symlink failed (non-fatal): \("\(error)")")
                }
            } else {
                AppLog.shared.info("step 3: user-visible URL unavailable; skipping symlink")
            }
        } else {
            AppLog.shared.info("step 3: NSFileProviderManager(for:) nil; skipping symlink")
        }

        // 4. Record in the in-memory + persisted registry.
        let mount = DirectMount(
            id: id,
            displayName: displayName,
            config: config,
            createdAt: Date(),
            symlinkName: symlinkName
        )
        mounts.append(mount)
        persist()
        AppLog.shared.info("createMount DONE id=\(domainID) total-mounts=\(mounts.count)")
        return mount
    }

    /// Convenience factories per protocol. Each one just builds the
    /// appropriate StoredMountConfig case and defers to createMount.
    /// Keeps form view-models strongly typed without knowing the enum.

    public func createFTPMount(
        name: String, host: String, port: Int, user: String, password: String,
        rootPath: String = "/", ftps: Bool = false
    ) async throws -> DirectMount {
        let inner = FTPMountConfig(
            host: host, port: port, user: user,
            rootPath: rootPath.isEmpty ? "/" : rootPath, ftps: ftps
        )
        return try await createMount(name: name, config: .ftp(inner), password: password)
    }

    public func createSFTPMount(
        name: String, host: String, port: Int, user: String, password: String,
        rootPath: String = "/", useSSHAgent: Bool = false
    ) async throws -> DirectMount {
        let inner = SFTPMountConfig(
            host: host, port: port, user: user,
            rootPath: rootPath.isEmpty ? "/" : rootPath, useSSHAgent: useSSHAgent
        )
        return try await createMount(name: name, config: .sftp(inner), password: password)
    }

    public func createSMBMount(
        name: String, host: String, port: Int, share: String, user: String,
        password: String, rootPath: String = "/"
    ) async throws -> DirectMount {
        let inner = SMBMountConfig(
            host: host, port: port, share: share, user: user,
            rootPath: rootPath.isEmpty ? "/" : rootPath
        )
        return try await createMount(name: name, config: .smb(inner), password: password)
    }

    public func createDropboxMount(
        name: String, accessToken: String
    ) async throws -> DirectMount {
        // Dropbox token plays the role of "password" in our keychain.
        return try await createMount(name: name, config: .dropbox(DropboxMountConfig()), password: accessToken)
    }

    public func createWebDAVMount(
        name: String, url: String, user: String, password: String,
        pathPrefix: String = "/"
    ) async throws -> DirectMount {
        let inner = WebDAVMountConfig(url: url, user: user, pathPrefix: pathPrefix)
        return try await createMount(name: name, config: .webdav(inner), password: password)
    }

    public func createGDriveMount(
        name: String, clientID: String, clientSecret: String,
        refreshToken: String, cachedAccessToken: String = ""
    ) async throws -> DirectMount {
        let inner = GDriveMountConfig(
            clientID: clientID, clientSecret: clientSecret,
            cachedAccessToken: cachedAccessToken
        )
        // Refresh token plays the role of "password" in the keychain.
        return try await createMount(name: name, config: .gdrive(inner), password: refreshToken)
    }

    public func createOneDriveMount(
        name: String, clientID: String, clientSecret: String = "",
        refreshToken: String, cachedAccessToken: String = ""
    ) async throws -> DirectMount {
        let inner = OneDriveMountConfig(
            clientID: clientID, clientSecret: clientSecret,
            cachedAccessToken: cachedAccessToken
        )
        return try await createMount(name: name, config: .onedrive(inner), password: refreshToken)
    }

    public func createS3Mount(
        name: String, endpoint: String, bucket: String,
        region: String = "us-east-1",
        accessKeyID: String, secretAccessKey: String,
        prefix: String = "", secure: Bool = true,
        usePathStyle: Bool = false, sessionToken: String = ""
    ) async throws -> DirectMount {
        let inner = S3MountConfig(
            endpoint: endpoint, bucket: bucket, region: region,
            accessKeyID: accessKeyID, prefix: prefix,
            secure: secure, usePathStyle: usePathStyle,
            sessionToken: sessionToken
        )
        // Secret access key plays the role of "password" in the keychain.
        return try await createMount(name: name, config: .s3(inner), password: secretAccessKey)
    }

    /// Remove a direct mount: drop the symlink, unregister the
    /// FileProvider domain, wipe the keychain item + plist, prune
    /// from the registry.
    public func removeMount(_ mount: DirectMount) async throws {
        // 1. Symlink — best effort.
        try? symlinks.removeSymlink(name: mount.symlinkName)

        // 2. Unregister domain.
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: mount.domainID),
            displayName: mount.displayName
        )
        do {
            try await NSFileProviderManager.remove(domain)
        } catch {
            // Log but keep cleaning up — if the domain was already
            // gone (extension crashed, user removed via Finder, etc.)
            // we don't want to strand the rest of the state.
            AppLog.shared.error("remove domain failed: \(error.localizedDescription)")
        }

        // 3. Config + keychain.
        try? keychain.delete(domainID: mount.domainID)
        try? configStore.delete(domainID: mount.domainID)

        // 4. Registry.
        mounts.removeAll { $0.id == mount.id }
        persist()
    }

    /// Look up a direct mount by its UUID (the same ID the sidebar
    /// passes through when the user clicks a row).
    public func mount(withID id: UUID) -> DirectMount? {
        mounts.first { $0.id == id }
    }

    /// Feed a parsed log line into the per-mount buffer if it's
    /// tagged with a `mount` field matching one of our domains.
    /// Lines with no `mount` tag or a tag we don't recognise are
    /// dropped — the central log view still sees them via
    /// logRepository; this router is for the detail view's
    /// mount-scoped strip only.
    public func applyLogLine(_ line: ParsedLogLine) {
        guard let mount = line.mount else { return }
        let knownIDs = Set(mounts.map { $0.domainID })
        guard knownIDs.contains(mount) else { return }
        let entry = AttachedDiskLogLine(
            timestamp: line.timestamp,
            level: line.level,
            message: line.message,
            source: line.source
        )
        var bucket = mountLogs[mount] ?? []
        bucket.append(entry)
        if bucket.count > Self.logCap {
            bucket.removeFirst(bucket.count - Self.logCap)
        }
        mountLogs[mount] = bucket
    }

    /// Read-only accessor for the log strip. Returns the most recent
    /// `tail` lines for the given domain, **newest-first** — the
    /// detail view renders them top-down so new events appear where
    /// the eye lands first.
    public func logs(forDomainID id: String, tail: Int = 200) -> [AttachedDiskLogLine] {
        let all = mountLogs[id] ?? []
        let windowed = all.count <= tail ? all : Array(all.suffix(tail))
        return windowed.reversed()
    }

    /// Read-only accessor for the per-mount I/O stats. Returns an empty
    /// (zero-counters, zero-samples) `IOStats` if the mount hasn't
    /// emitted an `io.stats` event yet — keeps the detail view's view
    /// model unconditional.
    public func stats(forDomainID id: String) -> IOStats {
        mountStats[id] ?? IOStats()
    }

    /// Route a kind-tagged extension event to the matching mount.
    /// Today only handles `io.stats`; other event kinds are reserved
    /// for future use (e.g. mount.online/offline). Lines without a
    /// `mount` tag, or for an unknown domain, are ignored.
    public func applyExtensionEvent(kind: String, fields: [String: String]) {
        guard let mountID = fields["mount"] else { return }
        let knownIDs = Set(mounts.map { $0.domainID })
        guard knownIDs.contains(mountID) else { return }

        switch kind {
        case "io.stats":
            var stats = mountStats[mountID] ?? IOStats()
            stats.absorb(IOCounters(fields: fields))
            mountStats[mountID] = stats
        case "mount.error":
            mountErrors[mountID] = MountConnectionError(
                summary: fields["summary"] ?? "Mount error",
                detail:  fields["detail"]  ?? "",
                op:      fields["op"]      ?? "?",
                path:    fields["path"]
            )
        case "mount.error.cleared":
            mountErrors.removeValue(forKey: mountID)
        default:
            break
        }
    }

    /// Read-only accessor for the per-mount connection error banner.
    /// Returns nil when the mount has no recorded failure (or the most
    /// recent op succeeded and emitted `mount.error.cleared`).
    public func connectionError(forDomainID id: String) -> MountConnectionError? {
        mountErrors[id]
    }

    /// Clear the connection-error banner for a mount. Used by the
    /// "Dismiss" action in the detail view; the next failed op will
    /// repopulate it.
    public func dismissConnectionError(forDomainID id: String) {
        mountErrors.removeValue(forKey: id)
    }

    /// Query NSFileProviderManager for the list of registered domains
    /// and check whether this mount's domain is among them. Authoritative
    /// — doesn't trust local state.
    public func isMounted(_ mount: DirectMount) async -> Bool {
        let domains: [NSFileProviderDomain] = await withCheckedContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
                continuation.resume(returning: domains)
            }
        }
        return domains.contains { $0.identifier.rawValue == mount.domainID }
    }

    /// Re-register a previously unmounted domain. Leaves the config
    /// plist + keychain entry intact (they're what make "unmount" a
    /// reversible action rather than "remove"). Re-creates the
    /// `~/diskjockey/<name>` symlink best-effort.
    public func mountDomain(_ mount: DirectMount) async throws {
        AppLog.shared.info("mountDomain id=\(mount.domainID)")
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: mount.domainID),
            displayName: mount.displayName
        )
        do {
            try await NSFileProviderManager.add(domain)
            AppLog.shared.info("mountDomain: domain registered")
        } catch {
            AppLog.shared.error("mountDomain FAILED: \("\(error)")")
            throw DirectMountError.domainRegistrationFailed(underlying: error)
        }

        // Re-drop the symlink. Best-effort; non-fatal if the sandbox
        // blocks it (same as the original create path).
        if let manager = NSFileProviderManager(for: domain),
           let visibleURL = try? await userVisibleURL(for: manager) {
            do {
                _ = try symlinks.createSymlink(name: mount.symlinkName, target: visibleURL)
                AppLog.shared.info("mountDomain: symlink re-created")
            } catch {
                AppLog.shared.error("mountDomain: symlink failed (non-fatal): \("\(error)")")
            }
        }
    }

    /// Unregister the FileProvider domain so Finder drops its entry.
    /// Config + keychain are left in place so the user can re-mount
    /// without re-entering credentials. Use `removeMount` for a full
    /// deletion.
    public func unmountDomain(_ mount: DirectMount) async throws {
        AppLog.shared.info("unmountDomain id=\(mount.domainID)")
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: mount.domainID),
            displayName: mount.displayName
        )
        do {
            try await NSFileProviderManager.remove(domain)
            AppLog.shared.info("unmountDomain: domain removed")
        } catch {
            AppLog.shared.error("unmountDomain FAILED: \("\(error)")")
            throw error
        }

        // Drop the symlink — its target is about to go stale.
        try? symlinks.removeSymlink(name: mount.symlinkName)
    }

    /// Resolve the system-visible URL for a direct mount, if its
    /// FileProvider domain is currently registered.
    public func userVisibleURL(for mount: DirectMount) async throws -> URL {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: mount.domainID),
            displayName: mount.displayName
        )
        guard let manager = NSFileProviderManager(for: domain) else {
            throw DirectMountError.userVisibleURLUnavailable
        }
        return try await userVisibleURL(for: manager)
    }

    // MARK: - Private

    /// NSFileProviderManager exposes `getUserVisibleURL(for:)` with a
    /// callback; wrap it for async/await. `.rootContainer` returns
    /// the top of the mount's view in `~/Library/CloudStorage`.
    private func userVisibleURL(for manager: NSFileProviderManager) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            manager.getUserVisibleURL(for: .rootContainer) { url, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let url = url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(
                        throwing: DirectMountError.userVisibleURLUnavailable
                    )
                }
            }
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(mounts) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func loadPersisted(from defaults: UserDefaults) -> [DirectMount] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([DirectMount].self, from: data)) ?? []
    }
}
