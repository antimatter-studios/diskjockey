//
// DirectMount.swift — one entry of the host app's direct-mount registry.
//
// Lives in the library rather than beside DirectMountRegistry so that what
// the registry writes into the app-group UserDefaults suite can be tested
// host-free (`swift test`); see DirectMountRegistryStore.
//

import Foundation

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
    /// Per-mount policy (thumbnails, background fetch, …). Authoritative
    /// copy lives in `MountPolicyStore`; this field is the in-memory
    /// mirror so the UI doesn't have to round-trip the plist on every
    /// render. Defaults to `.default` so legacy persisted entries that
    /// pre-date this field decode cleanly (see `init(from:)`).
    public let policy: MountPolicy

    public init(
        id: UUID = UUID(),
        displayName: String,
        config: StoredMountConfig,
        createdAt: Date = Date(),
        symlinkName: String,
        policy: MountPolicy = .default
    ) {
        self.id = id
        self.displayName = displayName
        self.config = config
        self.createdAt = createdAt
        self.symlinkName = symlinkName
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, config, createdAt, symlinkName, policy
    }

    /// Defaulting decode for `policy` so the UserDefaults blob written
    /// before policies existed still round-trips. Missing key → use
    /// `.default`; matches the upgrade behaviour of `MountPolicyStore`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.config = try c.decode(StoredMountConfig.self, forKey: .config)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.symlinkName = try c.decode(String.self, forKey: .symlinkName)
        self.policy =
            (try? c.decode(MountPolicy.self, forKey: .policy)) ?? .default
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
