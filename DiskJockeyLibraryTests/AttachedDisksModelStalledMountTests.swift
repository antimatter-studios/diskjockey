//
// AttachedDisksModelStalledMountTests.swift — a preview row no mount
// follows says so (diskjockey#349).
//
// An extension's events make a `.mounting` preview row before the mount
// table lists the volume, so the user sees the fsck window. When no mount
// follows, the row used to say "mounting" for as long as the app ran. It
// now becomes `.mountStalled` after `mountingTimeout`, with a reason that
// names the partition and what to do about it.
//

import Foundation
import Testing
@testable import DiskJockeyLibrary

@Suite("AttachedDisksModel stalled mounts")
@MainActor
struct AttachedDisksModelStalledMountTests {

    /// A model whose clock the test moves, and whose mount table is empty.
    private func model(at start: Date) -> (AttachedDisksModel, (TimeInterval) -> Void) {
        let model = AttachedDisksModel(readMountTable: { _ in [] })
        var clock = start
        model.now = { clock }
        return (model, { clock = start.addingTimeInterval($0) })
    }

    @Test func aPreviewStaysMountingWithinTheTimeout() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let (model, advance) = model(at: start)
        model.applyExtensionEvent(kind: "ntfs.activate", fields: ["bsd": "disk9s1"])
        #expect(model.disks.map(\.status) == [.mounting])
        #expect(model.disks.first?.mountingSince == start)

        advance(AttachedDisksModel.mountingTimeout - 1)
        model.expireStalledMounts()
        #expect(model.disks.map(\.status) == [.mounting])
    }

    @Test func aPreviewNoMountFollowedSaysWhyAfterTheTimeout() throws {
        let (model, advance) = model(at: Date(timeIntervalSince1970: 1_800_000_000))
        model.applyExtensionEvent(kind: "ntfs.activate", fields: ["bsd": "disk9s1"])

        advance(AttachedDisksModel.mountingTimeout)
        model.expireStalledMounts()
        let status = try #require(model.disks.first?.status)
        guard case .mountStalled(let reason) = status else {
            Issue.record("a preview past the timeout is \(status), not .mountStalled")
            return
        }
        #expect(reason.contains("disk9s1"), "\(reason)")
        #expect(reason.contains("ntfs"), "\(reason)")
        #expect(reason.contains("Forget"), "\(reason)")
    }

    /// The pure half, which every mount-table pass runs: only a `.mounting`
    /// row with a start time is ever marked, so rows the mount table made
    /// are left alone.
    @Test func onlyATimedPreviewIsMarked() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var preview = AttachedDisk(bsd: "disk9s1", mountPath: "", devicePath: "/dev/disk9s1",
                                   fsType: "ntfs", name: "disk9s1", isWritable: true,
                                   status: .mounting)
        preview.mountingSince = now.addingTimeInterval(-AttachedDisksModel.mountingTimeout - 5)
        let untimed = AttachedDisk(bsd: "disk8s1", mountPath: "", devicePath: "/dev/disk8s1",
                                   fsType: "ntfs", name: "disk8s1", isWritable: true,
                                   status: .mounting)
        let live = AttachedDisk(bsd: "disk7s1", mountPath: "/Volumes/v", devicePath: "/dev/disk7s1",
                                fsType: "ext4", name: "v", isWritable: true)
        var disks = [preview, untimed, live]
        AttachedDisksModel.markStalledMounts(in: &disks, now: now)
        if case .mountStalled = disks[0].status {} else {
            Issue.record("the timed-out preview is \(disks[0].status)")
        }
        #expect(disks[1].status == .mounting)
        #expect(disks[2].status == .live)
    }
}
