//
// MountPolicy.swift — protocol-agnostic per-mount policy flags.
//
// Lives outside the per-protocol `*MountConfig` types so every
// connector (FTP/SFTP/SMB/Dropbox/WebDAV/GDrive/S3/OneDrive) carries
// the same toggles, even when its driver doesn't yet support what
// the toggle gates. For example, `fetchThumbnails` makes sense on a
// future SFTP-with-local-thumbnail-render path even though today
// only Dropbox actually has a server thumbnail API. Letting the
// toggle exist for every protocol means the UI is consistent and we
// don't need to refactor when adding more thumbnail backends.
//
// Persisted next to `StoredMountConfig` as a separate file under the
// shared app-group container — see `MountPolicyStore`. Separate file
// (rather than envelope-wrapping `StoredMountConfig`) keeps the
// per-protocol plists untouched and avoids a migration step for
// existing mounts: a missing policy file just means "use defaults",
// which is what we want anyway.
//

import Foundation

public struct MountPolicy: Codable, Sendable, Equatable {
    /// Whether the FileProvider extension is allowed to fetch
    /// thumbnails — both reactively (responding to Finder's
    /// `fetchThumbnailsForItemIdentifiers`) and proactively (the
    /// enumerator's pre-warm path). Disabling this skips both,
    /// even if `backgroundFetch` is on.
    public let fetchThumbnails: Bool

    /// Whether the enumerator pre-warms thumbnails for image-typed
    /// entries it sees, ahead of any Finder request. Lets us drive
    /// the cache instead of waiting for Finder, so e.g. switching
    /// from List view to Icon view shows previews instantly.
    /// Implies `fetchThumbnails == true`; if that's off this has
    /// nothing to pre-warm.
    public let backgroundFetch: Bool

    public init(fetchThumbnails: Bool = true,
                backgroundFetch: Bool = true) {
        self.fetchThumbnails = fetchThumbnails
        self.backgroundFetch = backgroundFetch
    }

    private enum CodingKeys: String, CodingKey {
        case fetchThumbnails, backgroundFetch
    }

    /// Default-friendly decode so a partially-populated plist (or a
    /// new field added later) decodes cleanly with sensible
    /// defaults instead of failing the whole load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.fetchThumbnails =
            (try? c.decode(Bool.self, forKey: .fetchThumbnails)) ?? true
        self.backgroundFetch =
            (try? c.decode(Bool.self, forKey: .backgroundFetch)) ?? true
    }

    public static let `default` = MountPolicy()
}

public enum MountPolicyStoreError: Error {
    case groupContainerUnavailable
    case ioFailed(String)
    case decodeFailed(String)
    case encodeFailed(String)
}

/// Plist-backed persistence for `MountPolicy`, keyed by FileProvider
/// domain identifier. Layout mirrors `MountConfigStore`:
///
///   <group-container>/MountPolicies/<domain-id>.plist
///
/// Missing file ⇒ `MountPolicy.default` — i.e. existing mounts
/// created before policies existed transparently inherit "everything
/// on", which is the upgrade behaviour users had before.
public struct MountPolicyStore: Sendable {
    public static let groupIdentifier = "group.com.antimatterstudios.diskjockey"
    private static let subdirName = "MountPolicies"

    public init() {}

    private func policiesDir() throws -> URL {
        let fm = FileManager.default
        guard let base = fm.containerURL(
            forSecurityApplicationGroupIdentifier: Self.groupIdentifier
        ) else {
            throw MountPolicyStoreError.groupContainerUnavailable
        }
        let dir = base.appendingPathComponent(Self.subdirName, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func url(for domainID: String) throws -> URL {
        try policiesDir().appendingPathComponent("\(domainID).plist")
    }

    public func save(_ policy: MountPolicy, domainID: String) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data: Data
        do {
            data = try encoder.encode(policy)
        } catch {
            throw MountPolicyStoreError.encodeFailed(error.localizedDescription)
        }
        let target = try url(for: domainID)
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            throw MountPolicyStoreError.ioFailed(error.localizedDescription)
        }
    }

    /// Returns the persisted policy for `domainID`, or
    /// `MountPolicy.default` if no file exists. We *don't* throw
    /// `notFound` here because the missing-file case is the
    /// upgrade path for legacy mounts — defaulting is the right
    /// behaviour, not an error.
    public func load(domainID: String) throws -> MountPolicy {
        let url = try url(for: domainID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .default
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MountPolicyStoreError.ioFailed(error.localizedDescription)
        }
        do {
            return try PropertyListDecoder().decode(MountPolicy.self, from: data)
        } catch {
            throw MountPolicyStoreError.decodeFailed(error.localizedDescription)
        }
    }

    public func delete(domainID: String) throws {
        let url = try url(for: domainID)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw MountPolicyStoreError.ioFailed(error.localizedDescription)
            }
        }
    }
}
