//
//  MountPersistenceTests.swift — the two plist stores the FileProvider
//  extension reads at spawn, and the policy struct's upgrade path.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  These files are the handoff between two processes: the host app writes
//  them, the extension reads them, and nothing checks that the two agree
//  because they are the same type on both sides — right up until an
//  extension built yesterday reads a plist written today. Both types are
//  built for that case and say so:
//
//    * MountPolicy decodes every field with `try?` and falls back to the
//      default, "so a partially-populated plist (or a new field added
//      later) decodes cleanly with sensible defaults instead of failing
//      the whole load".
//    * MountPolicyStore returns `.default` for a MISSING file, because
//      "the missing-file case is the upgrade path for legacy mounts".
//
//  Neither leniency was tested, which is the usual state of an upgrade
//  path: it is exercised once, by a user, on a version nobody has any
//  more.
//
//  AND THE TWO STORES DISAGREE ON PURPOSE. A missing policy defaults; a
//  missing config throws `.notFound`. That asymmetry is right — a mount
//  with no policy is a mount with default policy, while a mount with no
//  config is not a mount — but it is the kind of thing that gets
//  "tidied" into consistency by someone who has not read both comments.
//  Both directions are pinned below.
//
//  Both stores take a `directory:` parameter that defaults to the shared
//  container; see either store's own doc comment for why that exists.
//

import Foundation
import Testing
@testable import DiskJockeyLibrary

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mount-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - The policy struct

@Suite("MountPolicy")
struct MountPolicyTests {

    @Test func everythingIsOnByDefault() {
        let policy = MountPolicy()
        #expect(policy.fetchThumbnails)
        #expect(policy.backgroundFetch)
        #expect(MountPolicy.default == policy,
                "the `default` singleton must be the same thing the initialiser produces")
    }

    @Test func aRoundTripThroughABinaryPlistPreservesBothFlags() throws {
        for (thumbs, background) in [(true, true), (true, false), (false, true), (false, false)] {
            let policy = MountPolicy(fetchThumbnails: thumbs, backgroundFetch: background)
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let back = try PropertyListDecoder().decode(MountPolicy.self,
                                                        from: try encoder.encode(policy))
            #expect(back == policy, "(\(thumbs), \(background)) did not survive a plist round-trip")
        }
    }

    /// THE UPGRADE PATH. An extension reading a plist written before a field
    /// existed must not fail the whole load — it fills in the default.
    @Test func aPlistMissingAFieldDecodesToTheDefaultForIt() throws {
        let onlyThumbs = try JSONDecoder().decode(
            MountPolicy.self, from: Data(#"{"fetchThumbnails":false}"#.utf8))
        #expect(onlyThumbs.fetchThumbnails == false, "the field that IS present must be honoured")
        #expect(onlyThumbs.backgroundFetch == true, "the absent field takes its default")

        let onlyBackground = try JSONDecoder().decode(
            MountPolicy.self, from: Data(#"{"backgroundFetch":false}"#.utf8))
        #expect(onlyBackground.fetchThumbnails == true)
        #expect(onlyBackground.backgroundFetch == false)
    }

    @Test func anEmptyPlistDecodesToTheDefaultPolicy() throws {
        let policy = try JSONDecoder().decode(MountPolicy.self, from: Data("{}".utf8))
        #expect(policy == MountPolicy.default)
    }

    /// `try?` per field means a WRONG TYPE also falls back rather than
    /// throwing. That is the same leniency and worth stating, because it is
    /// the difference between a mount that loses one toggle and a mount that
    /// will not load at all.
    @Test func aFieldOfTheWrongTypeFallsBackRatherThanFailingTheLoad() throws {
        let policy = try JSONDecoder().decode(
            MountPolicy.self, from: Data(#"{"fetchThumbnails":"yes","backgroundFetch":false}"#.utf8))
        #expect(policy.fetchThumbnails == true, "an unreadable field takes its default")
        #expect(policy.backgroundFetch == false, "the readable field beside it still decodes")
    }

    /// RECORDED, NOT ENFORCED. `backgroundFetch`'s comment says it "implies
    /// `fetchThumbnails == true`; if that's off this has nothing to
    /// pre-warm" — but nothing in the type enforces the implication, so the
    /// inconsistent combination is constructible and persists. Consumers
    /// have to check `fetchThumbnails` first; this says so in a place that
    /// will fail if the type ever starts normalising instead.
    @Test func theImpliedInvariantIsNotEnforcedByTheType() throws {
        let contradictory = MountPolicy(fetchThumbnails: false, backgroundFetch: true)
        #expect(contradictory.backgroundFetch == true,
                "if this now reads false, the type gained normalisation and callers no longer need to check fetchThumbnails first")
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let back = try PropertyListDecoder().decode(MountPolicy.self,
                                                    from: try encoder.encode(contradictory))
        #expect(back == contradictory, "the contradiction survives persistence too")
    }
}

// MARK: - The policy store

@Suite("MountPolicyStore")
struct MountPolicyStoreTests {

    @Test func aMissingFileIsTheDefaultPolicyRatherThanAnError() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MountPolicyStore(directory: dir)
        #expect(try store.load(domainID: "never-saved") == MountPolicy.default,
                "a legacy mount with no policy file must inherit the defaults, not fail to load")
    }

    @Test func whatWasSavedIsWhatLoads() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MountPolicyStore(directory: dir)
        let policy = MountPolicy(fetchThumbnails: false, backgroundFetch: false)
        try store.save(policy, domainID: "domain-1")
        #expect(try store.load(domainID: "domain-1") == policy)
    }

    @Test func policiesAreKeptPerDomain() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MountPolicyStore(directory: dir)
        try store.save(MountPolicy(fetchThumbnails: false, backgroundFetch: false), domainID: "a")
        try store.save(MountPolicy(fetchThumbnails: true, backgroundFetch: false), domainID: "b")
        #expect(try store.load(domainID: "a").fetchThumbnails == false)
        #expect(try store.load(domainID: "b").fetchThumbnails == true)
        #expect(try store.load(domainID: "c") == MountPolicy.default)
    }

    @Test func savingTwiceReplacesRatherThanAppends() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MountPolicyStore(directory: dir)
        try store.save(MountPolicy(fetchThumbnails: false, backgroundFetch: false), domainID: "d")
        try store.save(MountPolicy(fetchThumbnails: true, backgroundFetch: true), domainID: "d")
        #expect(try store.load(domainID: "d") == MountPolicy.default)
    }

    @Test func deletingReturnsTheDomainToTheDefaults() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MountPolicyStore(directory: dir)
        try store.save(MountPolicy(fetchThumbnails: false, backgroundFetch: false), domainID: "e")
        try store.delete(domainID: "e")
        #expect(try store.load(domainID: "e") == MountPolicy.default)
    }

    @Test func deletingSomethingThatIsNotThereIsNotAnError() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try MountPolicyStore(directory: dir).delete(domainID: "absent")
    }

    @Test func itCreatesItsDirectoryOnDemand() throws {
        let parent = try scratch()
        defer { try? FileManager.default.removeItem(at: parent) }
        let nested = parent.appendingPathComponent("not/created/yet", isDirectory: true)
        let store = MountPolicyStore(directory: nested)
        try store.save(MountPolicy(fetchThumbnails: false), domainID: "f")
        #expect(try store.load(domainID: "f").fetchThumbnails == false)
    }
}

// MARK: - The config store

@Suite("MountConfigStore")
struct MountConfigStoreTests {

    private func sample(_ scheme: DirectMountScheme) -> StoredMountConfig {
        switch scheme {
        case .ftp:      return .ftp(FTPMountConfig(host: "h", user: "u"))
        case .sftp:     return .sftp(SFTPMountConfig(host: "h", port: 2222, user: "u"))
        case .smb:      return .smb(SMBMountConfig(host: "h", share: "s", user: "u"))
        case .dropbox:  return .dropbox(DropboxMountConfig(appKey: "k", accountLabel: "l"))
        case .webdav:   return .webdav(WebDAVMountConfig(url: "https://d", user: "u"))
        case .gdrive:   return .gdrive(GDriveMountConfig(clientID: "c", clientSecret: "s"))
        case .s3:       return .s3(S3MountConfig(endpoint: "e", bucket: "b", accessKeyID: "k"))
        case .onedrive: return .onedrive(OneDriveMountConfig(clientID: "c"))
        }
    }

    /// EVERY SCHEME, because the plist root key is the enum case name and
    /// each case's struct is decoded separately — so a Codable break is
    /// per-scheme, not global, and a test of one scheme proves nothing
    /// about the other seven.
    @Test func everySchemeSurvivesTheDiskRoundTrip() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MountConfigStore(directory: dir)
        for scheme in DirectMountScheme.allCases {
            let config = sample(scheme)
            try store.save(config, domainID: scheme.rawValue)
            let back = try store.load(domainID: scheme.rawValue)
            #expect(back == config, "\(scheme) did not survive the store")
            #expect(back.scheme == scheme)
        }
        #expect(try store.allDomainIDs().sorted() == DirectMountScheme.allCases.map(\.rawValue).sorted())
    }

    /// THE ASYMMETRY WITH THE POLICY STORE, ON PURPOSE. A mount with no
    /// policy is a mount with the default policy; a mount with no config is
    /// not a mount.
    @Test func aMissingConfigThrowsNotFoundRatherThanDefaulting() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MountConfigStore(directory: dir)
        #expect(throws: MountConfigStoreError.self) {
            _ = try store.load(domainID: "never-saved")
        }
        do {
            _ = try store.load(domainID: "never-saved")
            Issue.record("load of an absent config did not throw")
        } catch let error as MountConfigStoreError {
            guard case .notFound(let domainID) = error else {
                Issue.record("expected .notFound, got \(error)")
                return
            }
            #expect(domainID == "never-saved", "the error must name the domain that is missing")
        }
    }

    /// `exists` is the non-throwing check the extension uses to decide
    /// "direct path?" vs "XPC fallback?", so a wrong answer picks the wrong
    /// mount strategy.
    @Test func existsTracksTheFile() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MountConfigStore(directory: dir)
        #expect(store.exists(domainID: "x") == false)
        try store.save(sample(.smb), domainID: "x")
        #expect(store.exists(domainID: "x") == true)
        try store.delete(domainID: "x")
        #expect(store.exists(domainID: "x") == false)
    }

    @Test func deletingSomethingThatIsNotThereIsNotAnError() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try MountConfigStore(directory: dir).delete(domainID: "absent")
    }

    /// `allDomainIDs` is what the host app reconciles against
    /// NSFileProviderManager on startup, so a stray file in the directory
    /// must not become a phantom domain.
    @Test func allDomainIDsIgnoresAnythingThatIsNotAPlist() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MountConfigStore(directory: dir)
        try store.save(sample(.ftp), domainID: "real-one")
        try Data("junk".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data("junk".utf8).write(to: dir.appendingPathComponent("no-extension"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("a-directory.plist"), withIntermediateDirectories: true)
        let ids = try store.allDomainIDs()
        #expect(ids.contains("real-one"))
        #expect(!ids.contains("notes"))
        #expect(!ids.contains("no-extension"))
        // A DIRECTORY NAMED *.plist IS LISTED, which is worth knowing: the
        // filter is on the extension, not on the file type, so reconciling
        // will then fail to load it. Recorded rather than asserted away.
        #expect(ids.contains("a-directory"),
                "if this now fails, the filter learned to check for a regular file, and the reconcile path got safer")
    }

    @Test func anEmptyDirectoryHasNoDomains() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try MountConfigStore(directory: dir).allDomainIDs().isEmpty)
    }

    @Test func aCorruptPlistIsReportedAsADecodeFailureNotAsAbsence() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MountConfigStore(directory: dir)
        try Data("this is not a plist".utf8).write(to: dir.appendingPathComponent("broken.plist"))
        do {
            _ = try store.load(domainID: "broken")
            Issue.record("a corrupt plist loaded successfully")
        } catch let error as MountConfigStoreError {
            guard case .decodeFailed = error else {
                Issue.record("expected .decodeFailed, got \(error) — a corrupt config must not read as a missing one")
                return
            }
        }
    }

    /// The domain identifier is interpolated straight into a path
    /// component, and this is what that means: an id containing a
    /// separator addresses a subdirectory rather than being rejected or
    /// escaped. Real ids are NSFileProviderDomain UUIDs, so this is a
    /// note about trust rather than a live defect — recorded so it is
    /// known rather than discovered.
    @Test func aDomainIdentifierIsTrustedToBeAPathComponent() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MountConfigStore(directory: dir)
        #expect(throws: (any Error).self) {
            try store.save(sample(.ftp), domainID: "nested/id")
        }
        #expect(store.exists(domainID: "nested/id") == false)
    }
}
