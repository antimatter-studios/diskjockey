//
//  AttachedDisksModelRefreshTests.swift — a slow `mount` must not stop the UI.
//
//  AttachedDisksModel polls every three seconds, and each pass runs
//  `/sbin/mount` and then asks every listed volume for its size. It used to
//  do that synchronously on the main actor, so a slow mount table, or one
//  spun-down or hung volume, froze the app for as long as the pass took,
//  and a pass that outlasted the interval kept the main queue from ever
//  draining (diskjockey#248, the sibling of #230).
//
//  The reader here stands in for the mount table and can be held shut, so
//  a pass can be caught mid-flight without a real mount or a timing guess.
//  Its gate times out rather than waiting forever: a model that reads the
//  mount table on the main actor then fails these cases instead of hanging
//  the suite.
//

import Foundation
import Testing
@testable import DiskJockeyLibrary

/// A mount-table double: one ext4 volume, and a gate that holds every read
/// until the test opens it.
private final class FakeMountTable: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let gateTimeout: DispatchTimeInterval
    private var reads: [Bool] = []   // one entry per read: was it on the main thread?
    private var finished = 0

    init(gated: Bool) {
        gateTimeout = gated ? .seconds(1) : .never
        if !gated { open() }
    }

    func read(_ fsTypesOfInterest: Set<String>) -> [AttachedDisk] {
        lock.withLock { reads.append(Thread.isMainThread) }
        _ = gate.wait(timeout: .now() + gateTimeout)
        gate.signal() // an open gate stays open for the next caller
        lock.withLock { finished += 1 }
        return [AttachedDisk(
            bsd: "disk5s1",
            mountPath: "/Volumes/inline-vol",
            devicePath: "/dev/disk5s1",
            fsType: "ext4",
            name: "inline-vol",
            isWritable: true,
            info: ["fs": "ext4", "total_size": "1048576"]
        )]
    }

    func open() { gate.signal() }

    var started: Int { lock.withLock { reads.count } }
    var completed: Int { lock.withLock { finished } }
    var readsOnMainThread: Int { lock.withLock { reads.filter { $0 }.count } }
}

/// Polls from the main actor until `condition` holds. Each poll is itself
/// main-actor work, so a `true` also proves the main actor was free.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@Suite("AttachedDisksModel refresh")
@MainActor
struct AttachedDisksModelRefreshTests {

    @Test func aSlowPassLeavesTheMainActorFree() async {
        let mount = FakeMountTable(gated: true)
        let model = AttachedDisksModel(readMountTable: mount.read)

        model.refresh()
        #expect(mount.completed == 0, "refresh() waited for the mount table before returning")

        #expect(await eventually { mount.started >= 1 })
        #expect(mount.completed == 0, "the main actor only ran once the mount table had been read")

        mount.open()
        #expect(await eventually { !model.disks.isEmpty })
        #expect(mount.readsOnMainThread == 0)
    }

    @Test func refreshesDuringAPassDoNotQueueMorePasses() async {
        let mount = FakeMountTable(gated: true)
        let model = AttachedDisksModel(readMountTable: mount.read)

        for _ in 0..<5 { model.refresh() }
        #expect(await eventually { mount.started >= 1 })
        mount.open()
        #expect(await eventually { !model.disks.isEmpty })
        try? await Task.sleep(for: .milliseconds(100))

        #expect(mount.started == 1)
    }

    @Test func aRefreshAfterAPassHasFinishedStartsANewOne() async {
        let mount = FakeMountTable(gated: false)
        let model = AttachedDisksModel(readMountTable: mount.read)

        model.refresh()
        #expect(await eventually { mount.completed == 1 && !model.disks.isEmpty })
        model.refresh()

        #expect(await eventually { mount.started == 2 })
    }

    @Test func thePassMergesIntoThePreviewRowAnEventMadeMidPass() async {
        let mount = FakeMountTable(gated: true)
        let model = AttachedDisksModel(readMountTable: mount.read)

        model.refresh()
        #expect(await eventually { mount.started >= 1 })
        // An extension event arrives while the pass is still reading, and
        // stands up a preview row. The pass must fold into that row rather
        // than publish a table computed before the event was seen.
        model.applyExtensionEvent(kind: "volume.info", fields: ["bsd": "disk5s1", "fs": "ext4", "volume_uuid": "u-1"])
        #expect(model.disks.map(\.status) == [.mounting])
        mount.open()

        #expect(await eventually { model.disks.first?.status == .live })
        #expect(model.disks.count == 1)
        #expect(model.disks.first?.mountPath == "/Volumes/inline-vol")
        #expect(model.disks.first?.info["volume_uuid"] == "u-1")
    }
}
