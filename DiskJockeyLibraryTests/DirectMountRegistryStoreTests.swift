//
//  DirectMountRegistryStoreTests.swift — what the direct-mount registry
//  leaves in the app-group UserDefaults suite (diskjockey#172).
//
//  WHY THIS FILE EXISTS
//  --------------------
//  A mount's config is written twice: once as the per-domain plist
//  (MountConfigStore, the copy the extension reads) and once inside the
//  registry's JSON blob in UserDefaults (the copy the sidebar reads). #160
//  took the OAuth access token out of the plist; a test on the plist alone
//  passes while the blob still carries whatever the config encodes. So these
//  read the suite's raw bytes after going through the registry's own store,
//  not the config's encoder in isolation.
//
//  Every test uses a scratch suite and removes it afterwards.
//

import Foundation
import Testing
@testable import DiskJockeyLibrary

private func withScratchSuite(_ body: (UserDefaults) throws -> Void) throws {
    let name = "dj-registry-store-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
}

private func rawBlob(_ defaults: UserDefaults) -> String {
    String(decoding: defaults.data(forKey: DirectMountRegistryStore.defaultsKey) ?? Data(),
           as: UTF8.self)
}

private let sessionToken = "STS-SESSION-TOKEN-6d21"
private let accessToken = "USER-ACCESS-TOKEN-4b7e"

private let s3WithSessionToken = StoredMountConfig.s3(S3MountConfig(
    endpoint: "s3.example.com", bucket: "b", accessKeyID: "AKID",
    sessionToken: sessionToken))

@Suite("DirectMountRegistryStore")
struct DirectMountRegistryStoreTests {

    @Test func aPersistedMountRoundTrips() throws {
        try withScratchSuite { defaults in
            let store = DirectMountRegistryStore(defaults: defaults)
            let mount = DirectMount(displayName: "Work",
                                    config: .ftp(FTPMountConfig(host: "h", user: "u")),
                                    symlinkName: "Work")
            store.save([mount])
            let loaded = store.load()
            #expect(loaded == [mount])
            #expect(loaded.first?.symlinkName == "Work")
        }
    }

    /// The red for #172: an S3 mount's STS session token is a stored,
    /// encoded field, so `persist()` wrote it into the suite in cleartext.
    @Test func anS3SessionTokenIsNotWrittenIntoTheSuite() throws {
        try withScratchSuite { defaults in
            let store = DirectMountRegistryStore(defaults: defaults)
            store.save([DirectMount(displayName: "Bucket", config: s3WithSessionToken,
                                    symlinkName: "Bucket")])
            #expect(!rawBlob(defaults).isEmpty, "nothing was persisted at all")
            #expect(!rawBlob(defaults).contains(sessionToken),
                    "the registry's UserDefaults blob carries the S3 session token")
        }
    }

    /// No mount of any scheme leaves an OAuth access token in the suite.
    @Test func anOAuthAccessTokenIsNotWrittenIntoTheSuite() throws {
        try withScratchSuite { defaults in
            let store = DirectMountRegistryStore(defaults: defaults)
            store.save([
                DirectMount(displayName: "G", config: .gdrive(GDriveMountConfig(
                    clientID: "c", clientSecret: "s", cachedAccessToken: accessToken)),
                            symlinkName: "G"),
                DirectMount(displayName: "O", config: .onedrive(OneDriveMountConfig(
                    clientID: "c", cachedAccessToken: accessToken)),
                            symlinkName: "O"),
            ])
            #expect(!rawBlob(defaults).contains(accessToken))
        }
    }

    /// A blob written by an older build still holds the credentials in the
    /// suite. Loading it must erase them, not merely decline to read them
    /// back: before this, nothing rewrote the blob until a mount was added,
    /// removed or had its policy changed, so a token could sit there for as
    /// long as the user's mount list did not change.
    @Test func loadingABlobLeftByAnOlderBuildErasesItsCredentials() throws {
        try withScratchSuite { defaults in
            let id = UUID()
            let legacy = """
            [{"id":"\(id.uuidString)","displayName":"Bucket","createdAt":0,"symlinkName":"Bucket",
              "config":{"s3":{"_0":{"endpoint":"s3.example.com","bucket":"b","region":"us-east-1",
                "accessKeyID":"AKID","prefix":"","secure":true,"usePathStyle":false,
                "sessionToken":"\(sessionToken)"}}}},
             {"id":"\(UUID().uuidString)","displayName":"G","createdAt":0,"symlinkName":"G",
              "config":{"gdrive":{"_0":{"clientID":"c","clientSecret":"s",
                "cachedAccessToken":"\(accessToken)","accountLabel":"me"}}}}]
            """
            defaults.set(Data(legacy.utf8), forKey: DirectMountRegistryStore.defaultsKey)

            let loaded = DirectMountRegistryStore(defaults: defaults).load()
            #expect(loaded.count == 2, "the legacy blob no longer decodes")
            #expect(loaded.first?.id == id && loaded.first?.displayName == "Bucket",
                    "erasing the credentials must keep every mount")
            #expect(!rawBlob(defaults).contains(sessionToken),
                    "a session token left by an older build is still in the suite after load")
            #expect(!rawBlob(defaults).contains(accessToken),
                    "an access token left by an older build is still in the suite after load")
        }
    }

    /// The per-domain plist is the other copy, and the one the extension
    /// reads: it must not carry the session token either.
    @Test func anS3SessionTokenIsNotWrittenIntoTheDomainPlist() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dj-registry-plist-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MountConfigStore(directory: dir)
        try store.save(s3WithSessionToken, domainID: "D")
        let bytes = try Data(contentsOf: dir.appendingPathComponent("D.plist"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains(sessionToken),
                "the per-domain plist carries the S3 session token")
    }
}

/// A keychain stand-in: the tests hold no keychain access group
/// entitlement, and a real item would outlive the test anyway.
private final class MemorySecrets: MountSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    var failSaves = false

    func save(password: String, domainID: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failSaves { throw MountKeychainError.osstatus(-34018, "save") }
        items[domainID] = password
    }
    func load(domainID: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let v = items[domainID] else { throw MountKeychainError.notFound }
        return v
    }
    func delete(domainID: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[domainID] = nil
    }
    var snapshot: [String: String] { lock.lock(); defer { lock.unlock() }; return items }
}

private func scratchConfigStore() -> (MountConfigStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dj-credentials-\(UUID().uuidString)", isDirectory: true)
    return (MountConfigStore(directory: dir), dir)
}

private func plistText(_ dir: URL, _ domainID: String) throws -> String {
    String(decoding: try Data(contentsOf: dir.appendingPathComponent("\(domainID).plist")),
           as: UTF8.self)
}

/// The session token's new home. Stripping it from the encoders is only
/// half a fix: the S3 driver needs it to sign every request, so it must
/// still reach `mountJSON` after a round trip through the plist.
@Suite("MountCredentials")
struct MountCredentialsTests {

    @Test func aSessionTokenSurvivesTheRoundTripThroughTheKeychain() throws {
        let (store, dir) = scratchConfigStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = MemorySecrets()
        let credentials = MountCredentials(secrets: secrets)

        try store.save(s3WithSessionToken, domainID: "D")
        try credentials.saveFieldSecrets(of: s3WithSessionToken, domainID: "D")

        #expect(!(try plistText(dir, "D")).contains(sessionToken))
        let resolved = try credentials.resolvedConfig(domainID: "D", store: store)
        #expect(resolved == s3WithSessionToken, "the keychain's token is not put back")
        #expect(resolved.mountJSON(password: "sk").contains(sessionToken),
                "the driver is no longer handed the session token")
        #expect(secrets.snapshot.keys.sorted() == [MountCredentials.sessionTokenAccount(domainID: "D")],
                "the token must not share the password's account")
    }

    @Test func anS3MountWithNoSessionTokenResolvesWithNone() throws {
        let (store, dir) = scratchConfigStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = MemorySecrets()
        let plain = StoredMountConfig.s3(S3MountConfig(endpoint: "e", bucket: "b", accessKeyID: "a"))
        try store.save(plain, domainID: "D")
        try MountCredentials(secrets: secrets).saveFieldSecrets(of: plain, domainID: "D")
        #expect(try MountCredentials(secrets: secrets).resolvedConfig(domainID: "D", store: store) == plain)
        #expect(secrets.snapshot.isEmpty, "an empty token was stored")
    }

    /// A plist written before this fix carries the token. Resolving it —
    /// what the extension does at spawn, with or without the host app —
    /// moves it into the keychain and rewrites the plist without it.
    @Test func aPlistLeftByAnOlderBuildIsMigratedOnFirstRead() throws {
        let (store, dir) = scratchConfigStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = #"{"s3":{"_0":{"endpoint":"s3.example.com","bucket":"b","region":"us-east-1","accessKeyID":"AKID","prefix":"","secure":true,"usePathStyle":false,"sessionToken":"STS-SESSION-TOKEN-6d21"}}}"#
        let object = try JSONSerialization.jsonObject(with: Data(legacy.utf8))
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
            .write(to: dir.appendingPathComponent("D.plist"))
        #expect((try plistText(dir, "D")).contains(sessionToken), "the fixture is not a legacy plist")

        let secrets = MemorySecrets()
        let resolved = try MountCredentials(secrets: secrets).resolvedConfig(domainID: "D", store: store)
        #expect(resolved == s3WithSessionToken)
        #expect(!(try plistText(dir, "D")).contains(sessionToken),
                "the legacy plist still carries the session token after it was read")
        #expect(secrets.snapshot[MountCredentials.sessionTokenAccount(domainID: "D")] == sessionToken,
                "the token was erased from the plist without reaching the keychain")
    }

    /// If the keychain refuses the token, the plist keeps it: a mount that
    /// still has a plaintext token beats one that can no longer sign.
    @Test func aFailedKeychainSaveLeavesTheLegacyPlistAlone() throws {
        let (store, dir) = scratchConfigStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = #"{"s3":{"_0":{"endpoint":"s3.example.com","bucket":"b","region":"us-east-1","accessKeyID":"AKID","prefix":"","secure":true,"usePathStyle":false,"sessionToken":"STS-SESSION-TOKEN-6d21"}}}"#
        let object = try JSONSerialization.jsonObject(with: Data(legacy.utf8))
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
            .write(to: dir.appendingPathComponent("D.plist"))

        let secrets = MemorySecrets()
        secrets.failSaves = true
        let resolved = try MountCredentials(secrets: secrets).resolvedConfig(domainID: "D", store: store)
        #expect(resolved == s3WithSessionToken, "the mount lost its token")
        #expect((try plistText(dir, "D")).contains(sessionToken),
                "the plist was stripped although the keychain never took the token")
    }

    @Test func deletingAMountsFieldSecretsRemovesTheToken() throws {
        let secrets = MemorySecrets()
        let credentials = MountCredentials(secrets: secrets)
        try credentials.saveFieldSecrets(of: s3WithSessionToken, domainID: "D")
        try credentials.deleteFieldSecrets(domainID: "D")
        #expect(secrets.snapshot.isEmpty)
        try credentials.deleteFieldSecrets(domainID: "never-had-one")
    }
}
