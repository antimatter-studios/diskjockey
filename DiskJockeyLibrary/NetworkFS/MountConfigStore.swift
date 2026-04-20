//
// MountConfigStore.swift — plist-backed persistence for DirectMountConfig
// keyed by domain identifier. Lives in the shared app-group container
// so the host app (writer) and the FileProvider extension (reader) see
// the same files.
//
// Layout on disk:
//
//   <group-container>/MountConfigs/<domain-id>.plist
//
// One file per mount. The filename is the NSFileProviderDomain identifier
// string (usually a UUID). Stays trivially easy to enumerate / clean up
// if mounts leak.
//

import Foundation

public enum MountConfigStoreError: Error {
    case groupContainerUnavailable
    case notFound(domainID: String)
    case decodeFailed(String)
    case encodeFailed(String)
    case ioFailed(String)
}

public struct MountConfigStore: Sendable {
    public static let groupIdentifier = "group.com.antimatterstudios.diskjockey"
    private static let subdirName = "MountConfigs"

    public init() {}

    /// The parent directory every stored config lives under. Created
    /// on demand. Intentionally a method, not a stored property, so
    /// permission changes mid-session are picked up.
    private func configsDir() throws -> URL {
        let fm = FileManager.default
        guard let base = fm.containerURL(
            forSecurityApplicationGroupIdentifier: Self.groupIdentifier
        ) else {
            throw MountConfigStoreError.groupContainerUnavailable
        }
        let dir = base.appendingPathComponent(Self.subdirName, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func url(for domainID: String) throws -> URL {
        try configsDir().appendingPathComponent("\(domainID).plist")
    }

    public func save(_ config: DirectMountConfig, domainID: String) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data: Data
        do {
            data = try encoder.encode(config)
        } catch {
            throw MountConfigStoreError.encodeFailed(error.localizedDescription)
        }
        let target = try url(for: domainID)
        do {
            try data.write(to: target, options: .atomic)
            NSLog("[MountConfigStore] wrote %d bytes → %@", data.count, target.path)
        } catch {
            NSLog("[MountConfigStore] write FAILED path=%@ err=%@",
                  target.path, error.localizedDescription)
            throw MountConfigStoreError.ioFailed(error.localizedDescription)
        }
    }

    public func load(domainID: String) throws -> DirectMountConfig {
        let url = try url(for: domainID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MountConfigStoreError.notFound(domainID: domainID)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MountConfigStoreError.ioFailed(error.localizedDescription)
        }
        do {
            return try PropertyListDecoder().decode(DirectMountConfig.self, from: data)
        } catch {
            throw MountConfigStoreError.decodeFailed(error.localizedDescription)
        }
    }

    /// Non-throwing existence check — handy for the extension to
    /// decide "direct path?" vs "XPC fallback?" without catching.
    public func exists(domainID: String) -> Bool {
        guard let url = try? url(for: domainID) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func delete(domainID: String) throws {
        let url = try url(for: domainID)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw MountConfigStoreError.ioFailed(error.localizedDescription)
            }
        }
    }

    /// List every domainID currently holding a config. Used by the
    /// host app on startup to reconcile against NSFileProviderManager.
    public func allDomainIDs() throws -> [String] {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(
            at: try configsDir(),
            includingPropertiesForKeys: nil
        )
        return urls
            .filter { $0.pathExtension == "plist" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }
}
