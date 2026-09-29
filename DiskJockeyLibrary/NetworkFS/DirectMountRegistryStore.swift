//
// DirectMountRegistryStore.swift — the host app's list of direct mounts,
// persisted as JSON in the app-group UserDefaults suite.
//
// This is the second place a mount's config is written, beside the
// per-domain plist MountConfigStore owns. The registry needs ids, display
// names, the symlink name and the policy; the config rides along so the
// sidebar can render a row without reading every plist. Whatever
// `StoredMountConfig` encodes therefore lands here too, which is why the
// encoding is tested through this type rather than assumed from the plist's
// (diskjockey#172).
//

import Foundation

public struct DirectMountRegistryStore {
    public static let defaultsKey = "DirectMountRegistry.mounts.v1"
    public static let suiteName = "group.com.antimatterstudios.diskjockey"

    private let defaults: UserDefaults

    /// - Parameter defaults: the suite to persist into. Defaults to the
    ///   shared app-group suite, falling back to `.standard` when the suite
    ///   is unavailable (tests / tooling); the tests pass a scratch suite.
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: Self.suiteName)
            ?? .standard
    }

    public func save(_ mounts: [DirectMount]) {
        guard let data = try? JSONEncoder().encode(mounts) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public func load() -> [DirectMount] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([DirectMount].self, from: data)) ?? []
    }
}
