//
//  AgentAuthorityTests.swift — the agent's checks, driven directly.
//
//  The agent itself cannot be tested host-free: it runs hdiutil and sits
//  behind an XPC listener. What decides whether it acts is in
//  AgentAuthority.swift, and that is what these tests reach, through the
//  DiskJockeyAgentCore view of it that Package.swift builds.
//
//  hdiutil output is built here as the plist hdiutil prints, key for key,
//  so the parser is exercised on the shape it meets in production.
//

import Foundation
import Testing
@testable import DiskJockeyAgentCore

// MARK: - fixtures

private func plist(_ object: Any) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
}

/// `hdiutil info -plist` for the given images.
func infoPlist(_ images: [(path: String, alias: String?, devices: [String])]) -> Data {
    plist(["images": images.map { image -> [String: Any] in
        var entry: [String: Any] = [
            "image-path": image.path,
            "system-entities": image.devices.map { ["dev-entry": $0, "content-hint": "GUID_partition_scheme"] },
        ]
        if let alias = image.alias { entry["image-alias"] = alias }
        return entry
    }])
}

/// A scratch directory, removed when the returned closure runs.
func scratchDirectory() -> (URL, () -> Void) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentAuthorityTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (dir, { try? FileManager.default.removeItem(at: dir) })
}

/// A regular file with some bytes in it.
func makeImage(in dir: URL, named name: String = "disk.img") -> URL {
    let url = dir.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 4096))
    return url
}

// MARK: - names

@Suite struct BSDNames {
    @Test(arguments: ["/dev/disk5", "/dev/disk12s3", "/dev/disk0s1"])
    func aDiskNameIsAccepted(_ name: String) {
        #expect(AgentAuthority.isBSDDiskName(name))
    }

    @Test(arguments: ["/dev/disk1 ; rm -rf /", "disk5", "/dev/rdisk5", "/dev/disk5s", "/dev/diskX", ""])
    func anythingElseIsNot(_ name: String) {
        #expect(!AgentAuthority.isBSDDiskName(name))
    }

    @Test func aSliceBelongsToItsWholeDisk() {
        #expect(AgentAuthority.wholeDisk(of: "/dev/disk5s2") == "/dev/disk5")
        #expect(AgentAuthority.wholeDisk(of: "/dev/disk5") == "/dev/disk5")
        #expect(AgentAuthority.wholeDisk(of: "/dev/rdisk5") == nil)
    }
}

// MARK: - hdiutil's plists

@Suite struct HdiutilOutput {
    @Test func infoListsEveryImageWithItsDevices() throws {
        let data = infoPlist([
            ("/Users/u/a.img", nil, ["/dev/disk5", "/dev/disk5s1"]),
            ("/Users/u/b.dmg", "/Users/u/link.dmg", ["/dev/disk6"]),
        ])
        let images = try #require(HdiutilPlist.images(fromInfo: data))
        #expect(images == [
            AttachedImage(imagePath: "/Users/u/a.img", devices: ["/dev/disk5", "/dev/disk5s1"]),
            AttachedImage(imagePath: "/Users/u/b.dmg", imageAlias: "/Users/u/link.dmg", devices: ["/dev/disk6"]),
        ])
    }

    @Test func attachReportsTheDevicesItProduced() throws {
        let data = plist(["system-entities": [
            ["dev-entry": "/dev/disk7", "content-hint": "GUID_partition_scheme"],
            ["dev-entry": "/dev/disk7s1", "content-hint": "Linux Filesystem"],
        ]])
        #expect(HdiutilPlist.devices(fromAttach: data) == ["/dev/disk7", "/dev/disk7s1"])
    }

    @Test func somethingThatIsNotThePlistIsNil() {
        #expect(HdiutilPlist.images(fromInfo: Data("hdiutil: info failed".utf8)) == nil)
        #expect(HdiutilPlist.devices(fromAttach: plist(["images": []])) == nil)
    }

    @Test func anImageIsFoundByItsAliasToo() {
        let image = AttachedImage(imagePath: "/private/var/x.img", imageAlias: "/Users/u/x.img", devices: [])
        #expect(image.isImage(at: "/Users/u/x.img"))
        #expect(!image.isImage(at: "/Users/u/y.img"))
    }
}

// MARK: - attach: the shape of the path

@Suite struct AttachPathShape {
    @Test func aMissingFileIsRefused() {
        let (dir, cleanup) = scratchDirectory(); defer { cleanup() }
        let path = dir.appendingPathComponent("absent.img").path
        guard case .failure = AgentAuthority.attachableImage(path, proof: -1) else {
            Issue.record("a path that does not exist was accepted"); return
        }
    }

    @Test func aDirectoryIsRefused() {
        let (dir, cleanup) = scratchDirectory(); defer { cleanup() }
        guard case .failure = AgentAuthority.attachableImage(dir.path, proof: -1) else {
            Issue.record("a directory was accepted as a disk image"); return
        }
    }
}

// MARK: - the ledger's bookkeeping

@Suite struct LedgerBookkeeping {
    @Test func anAttachIsRecordedAndForgottenOnDetach() {
        var ledger = AttachLedger()
        ledger.recordAttach(imagePath: "/Users/u/a.img", devices: ["/dev/disk5", "/dev/disk5s1"])
        #expect(ledger.images.count == 1)
        ledger.forget(device: "/dev/disk5s1")
        #expect(ledger.images.isEmpty)
    }

    @Test func aReusedDeviceReplacesTheStaleRecord() {
        var ledger = AttachLedger()
        ledger.recordAttach(imagePath: "/Users/u/a.img", devices: ["/dev/disk5"])
        ledger.recordAttach(imagePath: "/Users/u/b.img", devices: ["/dev/disk5"])
        #expect(ledger.images == [AttachedImage(imagePath: "/Users/u/b.img", devices: ["/dev/disk5"])])
    }

    @Test func pruneDropsWhatHdiutilNoLongerShows() {
        var ledger = AttachLedger()
        ledger.recordAttach(imagePath: "/Users/u/a.img", devices: ["/dev/disk5"])
        ledger.recordAttach(imagePath: "/Users/u/b.img", devices: ["/dev/disk6"])
        ledger.prune(attached: [AttachedImage(imagePath: "/Users/u/b.img", devices: ["/dev/disk6"])])
        #expect(ledger.images == [AttachedImage(imagePath: "/Users/u/b.img", devices: ["/dev/disk6"])])
    }

    @Test func theLedgerFileSurvivesARestart() {
        let (dir, cleanup) = scratchDirectory(); defer { cleanup() }
        let url = dir.appendingPathComponent("sub/attached-images.json")
        AttachLedgerFile(url: url).update { $0.recordAttach(imagePath: "/Users/u/a.img", devices: ["/dev/disk5"]) }
        let reread = AttachLedgerFile(url: url).update { $0 }
        #expect(reread.images == [AttachedImage(imagePath: "/Users/u/a.img", devices: ["/dev/disk5"])])
    }

    @Test func anUnreadableLedgerFileReadsAsEmpty() throws {
        let (dir, cleanup) = scratchDirectory(); defer { cleanup() }
        let url = dir.appendingPathComponent("attached-images.json")
        try Data("not json".utf8).write(to: url)
        #expect(AttachLedgerFile(url: url).update { $0 }.images.isEmpty)
    }
}
