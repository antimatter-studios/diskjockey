//
// DirectMountRegistry.swift — owns the lifecycle of "direct" mounts
// (those the host app configures and the FileProvider extension services
// WITHOUT going through the backend TCP server).
//
// Create:
//   1. Allocate a domain UUID.
//   2. Persist DirectMountConfig plist to the app-group container.
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
    public let config: DirectMountConfig
    public let createdAt: Date
    /// Filename of the symlink actually placed under `~/DiskJockey/`.
    /// May differ from `displayName` if we had to dedupe for a
    /// collision ("Work" → "Work-2").
    public let symlinkName: String

    public init(
        id: UUID = UUID(),
        displayName: String,
        config: DirectMountConfig,
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
    // registry). Spelled out manually because `DirectMountConfig`
    // only conforms to `Equatable`, which blocks the synthesised
    // Hashable derivation.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
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

    private let configStore: MountConfigStore
    private let keychain: MountKeychain
    private let symlinks: SymlinkManager
    private let defaults: UserDefaults

    private static let defaultsKey = "DirectMountRegistry.mounts.v1"
    private static let defaultsSuite = "group.com.antimatterstudios.diskjockey"

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
        NSLog("[DirectMount] registry init: loaded %d persisted mounts", mounts.count)
        for m in mounts {
            NSLog("[DirectMount]   persisted: id=%@ name=%@ host=%@:%d",
                  m.domainID, m.displayName, m.config.host, m.config.port)
        }
    }

    // MARK: - Public API

    /// Create a new direct FTP mount and register it with the system.
    /// Atomic-ish: we roll back in reverse if a late step fails.
    public func createFTPMount(
        name: String,
        host: String,
        port: Int,
        user: String,
        password: String,
        rootPath: String = "/",
        ftps: Bool = false
    ) async throws -> DirectMount {
        let id = UUID()
        let domainID = id.uuidString
        let displayName = name.isEmpty ? "FTP Mount" : name
        NSLog("[DirectMount] createFTPMount START id=%@ host=%@ port=%d user=%@ name=%@",
              domainID, host, port, user, displayName)

        let config = DirectMountConfig(
            scheme: .ftp,
            host: host,
            port: port,
            user: user,
            rootPath: rootPath.isEmpty ? "/" : rootPath,
            ftps: ftps
        )

        // 1a. Write config plist to the app-group container.
        NSLog("[DirectMount] step 1a: writing config plist")
        do {
            try configStore.save(config, domainID: domainID)
            NSLog("[DirectMount] step 1a: config plist saved")
        } catch {
            NSLog("[DirectMount] step 1a FAILED (config save): %@", "\(error)")
            throw error
        }

        // 1b. Stash the password in the shared keychain access group.
        NSLog("[DirectMount] step 1b: saving password to shared keychain")
        do {
            try keychain.save(password: password, domainID: domainID)
            NSLog("[DirectMount] step 1b: password saved")
        } catch {
            NSLog("[DirectMount] step 1b FAILED (keychain save): %@", "\(error)")
            try? configStore.delete(domainID: domainID)
            throw error
        }

        // 2. Register domain with FileProvider. Prefix the displayName
        // with "DiskJockey - " so the Finder sidebar entry is obviously
        // ours (and visually grouped if the user has multiple mounts).
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: domainID),
            displayName: "DiskJockey - \(displayName)"
        )
        NSLog("[DirectMount] step 2: NSFileProviderManager.add(domain)")
        do {
            try await NSFileProviderManager.add(domain)
            NSLog("[DirectMount] step 2: domain registered")
        } catch {
            NSLog("[DirectMount] step 2 FAILED (domain register): %@", "\(error)")
            try? keychain.delete(domainID: domainID)
            try? configStore.delete(domainID: domainID)
            throw DirectMountError.domainRegistrationFailed(underlying: error)
        }

        // 3. Drop a symlink at ~/DiskJockey/<name>. Best-effort — if
        // the sandbox blocks it we still keep the mount. Dedupe name
        // in-process to avoid clobbering an existing link.
        let symlinkName = symlinks.uniqueName(preferred: displayName)
        NSLog("[DirectMount] step 3: symlink dedupe → %@", symlinkName)
        if let manager = NSFileProviderManager(for: domain) {
            if let visibleURL = try? await userVisibleURL(for: manager) {
                NSLog("[DirectMount] step 3: user-visible URL = %@", visibleURL.path)
                do {
                    _ = try symlinks.createSymlink(name: symlinkName, target: visibleURL)
                    NSLog("[DirectMount] step 3: symlink created")
                } catch {
                    NSLog("[DirectMount] step 3: symlink failed (non-fatal): %@",
                          "\(error)")
                }
            } else {
                NSLog("[DirectMount] step 3: user-visible URL unavailable; skipping symlink")
            }
        } else {
            NSLog("[DirectMount] step 3: NSFileProviderManager(for:) nil; skipping symlink")
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
        NSLog("[DirectMount] createFTPMount DONE id=%@ total-mounts=%d",
              domainID, mounts.count)
        return mount
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
            NSLog("[DirectMountRegistry] remove domain failed: %@", error.localizedDescription)
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
