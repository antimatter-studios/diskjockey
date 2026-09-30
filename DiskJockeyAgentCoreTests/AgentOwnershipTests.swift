//
//  AgentOwnershipTests.swift — the agent acts only on what its caller could
//  have reached itself (diskjockey#94).
//
//  The connection's code-signing requirement proves the caller is our app.
//  These tests are about the next question: whether the app has any claim
//  to the particular image or device it names.
//
//  ATTACH needs proof of read access: an open file, sent with the request,
//  that is the image at the path. DETACH is refused for any device this
//  agent did not attach — including a BSD number it DID attach once, now
//  reused by a different image.
//

import Foundation
import Darwin
import Testing
@testable import DiskJockeyAgentCore

private func refused<T>(_ result: Result<T, String>) -> Bool {
    if case .failure = result { return true }
    return false
}

// MARK: - attach

@Suite struct AttachNeedsProof {
    @Test func noOpenFileIsRefused() {
        let (dir, cleanup) = scratchDirectory(); defer { cleanup() }
        let image = makeImage(in: dir)
        #expect(refused(AgentAuthority.attachableImage(image.path, proof: -1)),
                "an image was attached with nothing to show the caller may read it")
    }

    @Test func anOpenFileThatIsAnotherFileIsRefused() {
        let (dir, cleanup) = scratchDirectory(); defer { cleanup() }
        let image = makeImage(in: dir, named: "wanted.img")
        let decoy = makeImage(in: dir, named: "readable.img")
        let fd = open(decoy.path, O_RDONLY); defer { close(fd) }
        #expect(fd >= 0)
        #expect(refused(AgentAuthority.attachableImage(image.path, proof: fd)),
                "an open file for one image was accepted as proof for another")
    }

    @Test func aWriteOnlyFileIsRefused() {
        let (dir, cleanup) = scratchDirectory(); defer { cleanup() }
        let image = makeImage(in: dir)
        let fd = open(image.path, O_WRONLY); defer { close(fd) }
        #expect(fd >= 0)
        #expect(refused(AgentAuthority.attachableImage(image.path, proof: fd)),
                "a file open for writing only was accepted as proof of reading it")
    }

    @Test func aClosedDescriptorIsRefused() {
        let (dir, cleanup) = scratchDirectory(); defer { cleanup() }
        let image = makeImage(in: dir)
        let fd = open(image.path, O_RDONLY)
        close(fd)
        #expect(refused(AgentAuthority.attachableImage(image.path, proof: fd)))
    }

    @Test func theImageItselfOpenForReadingIsAccepted() throws {
        let (dir, cleanup) = scratchDirectory(); defer { cleanup() }
        let image = makeImage(in: dir)
        let fd = open(image.path, O_RDONLY); defer { close(fd) }
        let resolved = try AgentAuthority.attachableImage(image.path, proof: fd).get()
        #expect(resolved == AgentAuthority.canonical(image.path))
    }

    @Test func aSymlinkIsResolvedAndTheProofIsForItsTarget() throws {
        let (dir, cleanup) = scratchDirectory(); defer { cleanup() }
        let image = makeImage(in: dir)
        let link = dir.appendingPathComponent("link.img")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
        let fd = open(image.path, O_RDONLY); defer { close(fd) }
        let resolved = try AgentAuthority.attachableImage(link.path, proof: fd).get()
        #expect(resolved == AgentAuthority.canonical(image.path))
    }
}

// MARK: - detach

@Suite struct DetachNeedsOwnership {
    let ours = AttachedImage(imagePath: "/Users/u/ours.img", devices: ["/dev/disk5", "/dev/disk5s1"])

    func ledger() -> AttachLedger {
        var ledger = AttachLedger()
        ledger.recordAttach(imagePath: ours.imagePath, devices: ours.devices)
        return ledger
    }

    @Test func aDeviceThisAgentAttachedMayBeDetached() {
        #expect(!refused(ledger().authorizeDetach("/dev/disk5", attached: [ours])))
        #expect(!refused(ledger().authorizeDetach("/dev/disk5s1", attached: [ours])))
    }

    @Test func aDeviceThisAgentNeverAttachedIsRefused() {
        let usbDrive = AttachedImage(imagePath: "/Users/u/other.dmg", devices: ["/dev/disk9"])
        #expect(refused(ledger().authorizeDetach("/dev/disk9", attached: [ours, usbDrive])),
                "a disk image this agent never attached was detached")
    }

    @Test func aDiskThatIsNotAnImageAtAllIsRefused() {
        #expect(refused(ledger().authorizeDetach("/dev/disk2", attached: [ours])),
                "a device hdiutil does not show as an attached image was detached")
    }

    @Test func aReusedNumberIsNotOurs() {
        // Our image was ejected in Finder; /dev/disk5 now belongs to
        // somebody else's image. A record of the number alone would hand it
        // over.
        let reused = AttachedImage(imagePath: "/Users/u/someone-else.dmg", devices: ["/dev/disk5"])
        #expect(refused(ledger().authorizeDetach("/dev/disk5", attached: [reused])),
                "a reused BSD number was detached on the strength of an old record")
    }

    @Test func anEmptyLedgerRefusesEverything() {
        #expect(refused(AttachLedger().authorizeDetach("/dev/disk5", attached: [ours])))
    }
}
