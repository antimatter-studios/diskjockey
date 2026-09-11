//
//  NetworkFSPersonalityTests.swift — the eight mount personalities, their
//  driver IDs, and the JSON each hands to its Go driver.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  This layer had no tests at all. It is also the layer whose mistakes are
//  the hardest to see from the outside, because every one of them fails
//  SILENTLY on the far side of a C ABI:
//
//    * `driverType` is "part of the C ABI, not cosmetic" by its own comment.
//      A wrong integer dispatches to a different Go driver, which then
//      rejects a config it never expected. Nothing in Swift notices.
//    * `mountJSON` keys are read out of `map[string]string` by each Go
//      driver's `Mount()`. A renamed or missing key is a nil field on the
//      Go side, not a compile error here.
//    * `StoredMountConfig.scheme` is eight hand-written `case .x: return .x`
//      lines. That is exactly the shape a copy-paste gets wrong, and getting
//      it wrong routes a mount to the wrong driver.
//    * Every value must be a STRING. Go decodes into map[string]string, so
//      a numeric or boolean JSON value fails to decode there and here it is
//      just a dictionary literal.
//
//  WHAT THESE TESTS DO NOT DO. They do not verify that the key names match
//  what the Go drivers actually read — that lives in a sibling repository
//  which this target deliberately does not clone. What they pin is that the
//  keys, the driver IDs and the string-ness do not CHANGE without somebody
//  saying so, and that the omit-when-empty branches behave as documented.
//
//  Host-free by construction: no app, no extension, no FSKit, no I/O.
//

import Foundation
import Testing
@testable import DiskJockeyLibrary

// MARK: - Helpers

/// Decode a personality's JSON back into a dictionary, asserting on the way
/// that it is a JSON object whose every value is a string.
private func mountDict(_ json: String,
                       _ sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: String] {
    let data = Data(json.utf8)
    let any = try JSONSerialization.jsonObject(with: data)
    let object = try #require(any as? [String: Any], "not a JSON object: \(json)",
                              sourceLocation: sourceLocation)
    var out: [String: String] = [:]
    for (key, value) in object {
        let string = value as? String
        #expect(string != nil,
                "key \"\(key)\" is \(type(of: value)), not String; the Go drivers decode into map[string]string",
                sourceLocation: sourceLocation)
        out[key] = string ?? ""
    }
    return out
}

/// Every scheme paired with a config of that scheme, so a test can iterate
/// the whole set rather than naming eight cases and forgetting the ninth.
private let allStored: [StoredMountConfig] = [
    .ftp(FTPMountConfig(host: "ftp.example.com", user: "u")),
    .sftp(SFTPMountConfig(host: "sftp.example.com", user: "u")),
    .smb(SMBMountConfig(host: "smb.example.com", share: "public", user: "u")),
    .dropbox(DropboxMountConfig()),
    .webdav(WebDAVMountConfig(url: "https://dav.example.com", user: "u")),
    .gdrive(GDriveMountConfig(clientID: "cid", clientSecret: "csecret")),
    .s3(S3MountConfig(endpoint: "s3.example.com", bucket: "b", accessKeyID: "AKIA")),
    .onedrive(OneDriveMountConfig(clientID: "cid")),
]

// MARK: - The C ABI

@Suite("driver type IDs")
struct DriverTypeTests {

    /// THE NUMBERS THEMSELVES, spelled out. `driverType`'s own comment says
    /// "DO NOT change these — they're part of the C ABI, not cosmetic", and
    /// a rule stated in a comment is not a rule anything enforces.
    @Test func driverTypesAreTheDocumentedIntegers() {
        #expect(DirectMountScheme.ftp.driverType == 1)
        #expect(DirectMountScheme.sftp.driverType == 2)
        #expect(DirectMountScheme.smb.driverType == 3)
        #expect(DirectMountScheme.dropbox.driverType == 4)
        #expect(DirectMountScheme.webdav.driverType == 5)
        #expect(DirectMountScheme.gdrive.driverType == 6)
        #expect(DirectMountScheme.s3.driverType == 7)
        #expect(DirectMountScheme.onedrive.driverType == 8)
    }

    /// And a new case cannot silently reuse an existing driver's ID, which
    /// would send its mounts to that driver.
    @Test func everySchemeHasItsOwnDriverType() {
        let ids = DirectMountScheme.allCases.map(\.driverType)
        #expect(Set(ids).count == ids.count,
                "two schemes share a driver_type: \(ids)")
        #expect(!ids.contains(0), "0 is not a registered driver type")
    }

    /// CaseIterable is what lets the checks above cover a case nobody
    /// remembered to add here. Pin the count so adding one is a decision.
    @Test func theSchemeSetIsTheEightWeSupport() {
        #expect(DirectMountScheme.allCases.count == 8)
        let raws = DirectMountScheme.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
    }

    /// The raw value is the on-disk spelling (the enum is Codable), so it is
    /// as much a compatibility surface as the integer is.
    @Test func rawValuesAreTheOnDiskSpellings() {
        #expect(DirectMountScheme(rawValue: "ftp") == .ftp)
        #expect(DirectMountScheme(rawValue: "sftp") == .sftp)
        #expect(DirectMountScheme(rawValue: "smb") == .smb)
        #expect(DirectMountScheme(rawValue: "dropbox") == .dropbox)
        #expect(DirectMountScheme(rawValue: "webdav") == .webdav)
        #expect(DirectMountScheme(rawValue: "gdrive") == .gdrive)
        #expect(DirectMountScheme(rawValue: "s3") == .s3)
        #expect(DirectMountScheme(rawValue: "onedrive") == .onedrive)
        #expect(DirectMountScheme(rawValue: "Dropbox") == nil,
                "raw values are case-sensitive; a capitalised one must not decode")
    }

    @Test("every scheme has a label and an icon", arguments: DirectMountScheme.allCases)
    func labelAndIcon(scheme: DirectMountScheme) {
        #expect(!scheme.displayName.isEmpty)
        guard case .asset(let name) = scheme.icon else { return }
        #expect(!name.isEmpty, "\(scheme) has an empty asset name")
    }
}

// MARK: - The envelope routes to the right driver

@Suite("StoredMountConfig routing")
struct StoredMountConfigRoutingTests {

    /// EIGHT HAND-WRITTEN LINES OF `case .x: return .x`. This is the check
    /// that makes a mis-pasted one visible, and it is why `allStored` pairs
    /// each case with a config of that same protocol: the wrapped type
    /// declares its own scheme statically, so the two can be compared
    /// without restating either.
    @Test func theEnvelopeReportsTheWrappedConfigsScheme() {
        var seen: Set<DirectMountScheme> = []
        for stored in allStored {
            let wrapped: DirectMountScheme
            switch stored {
            case .ftp:      wrapped = FTPMountConfig.scheme
            case .sftp:     wrapped = SFTPMountConfig.scheme
            case .smb:      wrapped = SMBMountConfig.scheme
            case .dropbox:  wrapped = DropboxMountConfig.scheme
            case .webdav:   wrapped = WebDAVMountConfig.scheme
            case .gdrive:   wrapped = GDriveMountConfig.scheme
            case .s3:       wrapped = S3MountConfig.scheme
            case .onedrive: wrapped = OneDriveMountConfig.scheme
            }
            #expect(stored.scheme == wrapped,
                    "envelope says \(stored.scheme) but the wrapped config says \(wrapped)")
            seen.insert(stored.scheme)
        }
        // AND THE FIXTURE COVERS EVERYTHING. Without this the loop above
        // passes a fixture that quietly lost a case.
        #expect(seen == Set(DirectMountScheme.allCases),
                "the fixture does not cover every scheme: missing \(Set(DirectMountScheme.allCases).subtracting(seen))")
    }

    @Test func theEnvelopeForwardsDriverType() {
        for stored in allStored {
            #expect(stored.driverType == stored.scheme.driverType)
        }
    }

    @Test func everySchemeHasADisplayLocation() {
        for stored in allStored {
            #expect(!stored.displayLocation.isEmpty, "\(stored.scheme) has no display location")
        }
        #expect(StoredMountConfig.smb(SMBMountConfig(host: "h", share: "s", user: "u")).displayLocation == "h/s")
        #expect(StoredMountConfig.ftp(FTPMountConfig(host: "h", user: "u")).displayLocation == "h:21")
        #expect(StoredMountConfig.s3(S3MountConfig(endpoint: "e", bucket: "b", accessKeyID: "k")).displayLocation == "e/b")
    }
}

// MARK: - What the Go side receives

@Suite("mountJSON")
struct MountJSONTests {

    /// ONE ASSERTION OVER ALL EIGHT, because "every value is a string" is a
    /// property of the ABI rather than of any one protocol, and a per-driver
    /// test would be the eighth place to forget it.
    @Test func everyPersonalityEncodesAJSONObjectOfStrings() throws {
        for stored in allStored {
            let dict = try mountDict(stored.mountJSON(password: "pw"))
            #expect(!dict.isEmpty, "\(stored.scheme) produced an empty config")
        }
    }

    /// Booleans reach Go as the STRINGS "true"/"false" — the map is
    /// map[string]string, so a real JSON boolean does not decode there.
    @Test func booleansAreEncodedAsStrings() throws {
        let ftps = try mountDict(FTPMountConfig(host: "h", user: "u", ftps: true).mountJSON(password: "p"))
        #expect(ftps["ftps"] == "true")
        let plain = try mountDict(FTPMountConfig(host: "h", user: "u", ftps: false).mountJSON(password: "p"))
        #expect(plain["ftps"] == "false")

        let agent = try mountDict(SFTPMountConfig(host: "h", user: "u", useSSHAgent: true).mountJSON(password: "p"))
        #expect(agent["use_ssh_agent"] == "true")

        let s3 = try mountDict(S3MountConfig(endpoint: "e", bucket: "b", accessKeyID: "k",
                                             secure: false, usePathStyle: true).mountJSON(password: "p"))
        #expect(s3["secure"] == "false")
        #expect(s3["use_path_style"] == "true")
    }

    /// Ports are integers in Swift and strings in the config map.
    @Test func portsCrossAsStringsAndDefaultsAreTheDocumentedOnes() throws {
        #expect(try mountDict(FTPMountConfig(host: "h", user: "u").mountJSON(password: "p"))["port"] == "21")
        #expect(try mountDict(SFTPMountConfig(host: "h", user: "u").mountJSON(password: "p"))["port"] == "22")
        #expect(try mountDict(SMBMountConfig(host: "h", share: "s", user: "u").mountJSON(password: "p"))["port"] == "445")
        #expect(try mountDict(SFTPMountConfig(host: "h", port: 2222, user: "u").mountJSON(password: "p"))["port"] == "2222")
    }

    @Test func s3CarriesItsDocumentedDefaults() throws {
        let dict = try mountDict(S3MountConfig(endpoint: "e", bucket: "b", accessKeyID: "k").mountJSON(password: "p"))
        #expect(dict["region"] == "us-east-1")
        #expect(dict["secure"] == "true")
        #expect(dict["use_path_style"] == "false")
    }

    /// THE PASSWORD GOES WHERE EACH DRIVER LOOKS FOR IT, and the key differs
    /// per protocol. Getting this wrong is an authentication failure whose
    /// only symptom is a rejected mount.
    @Test func theSecretLandsUnderTheKeyItsDriverReads() throws {
        let secret = "s3cr3t"
        #expect(try mountDict(FTPMountConfig(host: "h", user: "u").mountJSON(password: secret))["pass"] == secret)
        #expect(try mountDict(SFTPMountConfig(host: "h", user: "u").mountJSON(password: secret))["pass"] == secret)
        #expect(try mountDict(SMBMountConfig(host: "h", share: "s", user: "u").mountJSON(password: secret))["pass"] == secret)
        #expect(try mountDict(WebDAVMountConfig(url: "u", user: "u").mountJSON(password: secret))["pass"] == secret)
        #expect(try mountDict(S3MountConfig(endpoint: "e", bucket: "b", accessKeyID: "k").mountJSON(password: secret))["secret_access_key"] == secret)
        #expect(try mountDict(GDriveMountConfig(clientID: "c", clientSecret: "s").mountJSON(password: secret))["refresh_token"] == secret)
        #expect(try mountDict(OneDriveMountConfig(clientID: "c").mountJSON(password: secret))["refresh_token"] == secret)
    }

    /// S3's `access_key_id` is deliberately NOT the secret (see that file's
    /// header), so it must not be confused with it.
    @Test func s3SplitsIdentifierFromCredential() throws {
        let dict = try mountDict(S3MountConfig(endpoint: "e", bucket: "b", accessKeyID: "AKIAIDENT").mountJSON(password: "thesecret"))
        #expect(dict["access_key_id"] == "AKIAIDENT")
        #expect(dict["secret_access_key"] == "thesecret")
    }

    /// A PASSWORD IS ARBITRARY BYTES. This dict is hand-built into JSON, and
    /// a quote or a backslash in the wrong place produces a config the Go
    /// side cannot parse at all — a mount that fails with a JSON error rather
    /// than an auth error.
    @Test func awkwardSecretsSurviveEncoding() throws {
        for secret in [#"has "quotes""#,
                       #"back\slash"#,
                       "line\nbreak",
                       "tab\there",
                       "emoji 🔐 and ünïcødé",
                       #"{"looks":"like json"}"#,
                       ""] {
            let dict = try mountDict(SFTPMountConfig(host: "h", user: "u").mountJSON(password: secret))
            #expect(dict["pass"] == secret, "secret did not round-trip: \(secret.debugDescription)")
        }
    }

    /// Awkward FIELD values too, not just secrets — a share name with a
    /// quote in it is legal on the wire.
    @Test func awkwardFieldValuesSurviveEncoding() throws {
        let dict = try mountDict(SMBMountConfig(host: #"host"with"quotes"#, share: #"sh\are"#,
                                                user: "üser", rootPath: "/a b/c").mountJSON(password: "p"))
        #expect(dict["host"] == #"host"with"quotes"#)
        #expect(dict["share"] == #"sh\are"#)
        #expect(dict["user"] == "üser")
        #expect(dict["root"] == "/a b/c")
    }
}

// MARK: - The omit-when-empty branches

@Suite("optional fields")
struct OptionalFieldTests {

    /// S3 omits both optional keys rather than sending them empty. An empty
    /// `prefix` is not the same as no prefix on the Go side: one mounts the
    /// whole bucket, the other mounts a directory named "".
    @Test func s3OmitsEmptyOptionalsAndIncludesSetOnes() throws {
        let bare = try mountDict(S3MountConfig(endpoint: "e", bucket: "b", accessKeyID: "k").mountJSON(password: "p"))
        #expect(bare["prefix"] == nil)
        #expect(bare["session_token"] == nil)

        let full = try mountDict(S3MountConfig(endpoint: "e", bucket: "b", accessKeyID: "k",
                                               prefix: "data/", sessionToken: "tok").mountJSON(password: "p"))
        #expect(full["prefix"] == "data/")
        #expect(full["session_token"] == "tok")
    }

    /// Dropbox switches its whole credential model on whether an app key is
    /// configured: a bare account sends a long-lived access token, a
    /// registered app sends a refresh token. Two different keys, and only
    /// one of them at a time.
    @Test func dropboxPicksItsCredentialKeyFromWhetherAnAppKeyIsSet() throws {
        let bare = try mountDict(DropboxMountConfig().mountJSON(password: "tok"))
        #expect(bare["access_token"] == "tok")
        #expect(bare["refresh_token"] == nil)
        #expect(bare["app_key"] == nil)

        let app = try mountDict(DropboxMountConfig(appKey: "kk").mountJSON(password: "refresh"))
        #expect(app["app_key"] == "kk")
        #expect(app["refresh_token"] == "refresh")
        #expect(app["access_token"] == nil,
                "an app-key mount must not also send a long-lived access token")
    }

    @Test func gdriveIncludesACachedTokenOnlyWhenThereIsOne() throws {
        let cold = try mountDict(GDriveMountConfig(clientID: "c", clientSecret: "s").mountJSON(password: "r"))
        #expect(cold["access_token"] == nil)
        #expect(cold["client_id"] == "c")
        #expect(cold["client_secret"] == "s")

        let warm = try mountDict(GDriveMountConfig(clientID: "c", clientSecret: "s",
                                                   cachedAccessToken: "at").mountJSON(password: "r"))
        #expect(warm["access_token"] == "at")
    }

    /// OneDrive's client secret is optional (public clients use PKCE and
    /// have none), so an empty one must be omitted rather than sent blank.
    @Test func onedriveOmitsAnEmptyClientSecret() throws {
        let publicClient = try mountDict(OneDriveMountConfig(clientID: "c").mountJSON(password: "r"))
        #expect(publicClient["client_secret"] == nil)
        #expect(publicClient["access_token"] == nil)
        #expect(publicClient["client_id"] == "c")

        let confidential = try mountDict(OneDriveMountConfig(clientID: "c", clientSecret: "s",
                                                             cachedAccessToken: "at").mountJSON(password: "r"))
        #expect(confidential["client_secret"] == "s")
        #expect(confidential["access_token"] == "at")
    }
}

// MARK: - What goes on disk

@Suite("persistence")
struct PersistenceTests {

    /// The envelope is persisted as a plist per NSFileProviderDomain, so the
    /// plist encoder is the one that matters. A round-trip through it is the
    /// closest thing to "will the extension still read this after a restart".
    @Test func everySchemeRoundTripsThroughAPropertyList() throws {
        for stored in allStored {
            let data = try PropertyListEncoder().encode(stored)
            let back = try PropertyListDecoder().decode(StoredMountConfig.self, from: data)
            #expect(back == stored, "\(stored.scheme) did not survive a plist round-trip")
        }
    }

    @Test func everySchemeRoundTripsThroughJSON() throws {
        for stored in allStored {
            let data = try JSONEncoder().encode(stored)
            let back = try JSONDecoder().decode(StoredMountConfig.self, from: data)
            #expect(back == stored, "\(stored.scheme) did not survive a JSON round-trip")
        }
    }

    /// THE KEYCHAIN OWNS CREDENTIALS, and this is the assertion that says so.
    /// `mountJSON` takes the password as a parameter precisely so the plist on
    /// disk never carries it. Asserted against the VALUE rather than against a
    /// list of key names: a name check reads as stronger than it is, and the
    /// thing that matters is whether the secret is on disk, whatever the field
    /// happens to be called.
    @Test func theSecretPassedToMountJSONIsNeverPersisted() throws {
        let secret = "THE-KEYCHAIN-HALF-9f3a1c"
        for stored in allStored {
            // The secret is in the mount JSON, which is the point of it.
            #expect(stored.mountJSON(password: secret).contains(secret),
                    "\(stored.scheme) does not pass the secret to its driver at all")
            // And not in what goes on disk.
            let onDisk = try PropertyListEncoder().encode(stored)
            #expect(!String(decoding: onDisk, as: UTF8.self).contains(secret),
                    "\(stored.scheme)'s persisted form carries the secret that MountKeychain is supposed to own")
        }
    }

    /// AND ONE SECRET IS ON DISK ANYWAY — recorded here rather than asserted
    /// away, because it is a live finding and not a test bug (diskjockey#160).
    ///
    /// `GDriveMountConfig.cachedAccessToken` and OneDrive's equivalent are
    /// ordinary Codable fields, so `OAuthRefreshSupervisor` writing a freshly
    /// refreshed OAuth *access token* into the config puts that token in
    /// cleartext into the per-domain plist in the app-group container. The
    /// refresh token, which is the long-lived half, correctly goes to the
    /// keychain — so the split is half-applied rather than absent.
    ///
    /// `withKnownIssue` keeps the suite green while the decision is open AND
    /// makes the test fail the day it is fixed, which is when this comment
    /// needs deleting. A plain `#expect(persisted)` would pin the behaviour as
    /// desired; a deleted test would lose the finding.
    @Test func anOAuthAccessTokenReachesTheDiskInCleartext() throws {
        let token = "USER-ACCESS-TOKEN-4b7e"
        let configs: [StoredMountConfig] = [
            .gdrive(GDriveMountConfig(clientID: "c", clientSecret: "s", cachedAccessToken: token)),
            .onedrive(OneDriveMountConfig(clientID: "c", cachedAccessToken: token)),
        ]
        for stored in configs {
            let onDisk = String(decoding: try PropertyListEncoder().encode(stored), as: UTF8.self)
            withKnownIssue("diskjockey#160: cachedAccessToken is persisted in the domain plist") {
                #expect(!onDisk.contains(token),
                        "\(stored.scheme) writes a live access token to disk")
            }
        }
    }

    /// The OAuth configs decode missing fields to "" rather than throwing,
    /// which is what lets a plist written by an older build still load. That
    /// leniency is deliberate and worth pinning: without it, adding a field
    /// bricks every existing domain.
    @Test func theOAuthConfigsToleratePlistsWrittenBeforeTheirFieldsExisted() throws {
        let partial = Data(#"{"clientID":"only-this"}"#.utf8)
        let gdrive = try JSONDecoder().decode(GDriveMountConfig.self, from: partial)
        #expect(gdrive.clientID == "only-this")
        #expect(gdrive.clientSecret == "")
        #expect(gdrive.cachedAccessToken == "")

        let onedrive = try JSONDecoder().decode(OneDriveMountConfig.self, from: partial)
        #expect(onedrive.clientID == "only-this")
        #expect(onedrive.clientSecret == "")

        let empty = Data("{}".utf8)
        let dropbox = try JSONDecoder().decode(DropboxMountConfig.self, from: empty)
        #expect(dropbox.appKey == "")
        #expect(dropbox.accountLabel == "")
    }

    /// And the non-OAuth ones are NOT lenient, which is the other half of the
    /// same decision: a host or a share is not something to default.
    @Test func aConfigMissingItsHostDoesNotDecode() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SFTPMountConfig.self, from: Data(#"{"user":"u"}"#.utf8))
        }
    }
}
