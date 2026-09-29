//
//  RawDisksModelTests.swift — a slow `diskutil` must not stop the UI.
//
//  RawDisksModel polls every three seconds and each pass runs `diskutil`
//  once per disk. It used to do that synchronously on the main actor, so
//  a spun-down or slow disk froze the app for as long as `diskutil` took,
//  and on a slow machine a pass outlasted the interval and the main queue
//  never drained (diskjockey#230).
//
//  The runner here stands in for diskutil and can be held shut, so a pass
//  can be caught mid-flight without a real disk or a timing guess. Its
//  gate times out rather than waiting forever: a model that runs diskutil
//  on the main actor then fails these cases instead of hanging the suite.
//

import Foundation
import Testing
@testable import DiskJockeyLibrary

/// A `diskutil` double: one whole disk with one unformatted slice, and a
/// gate that holds every call until the test opens it.
private final class FakeDiskutil: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let gateTimeout: DispatchTimeInterval
    private var calls: [(args: [String], onMain: Bool)] = []
    private var finished = 0

    init(gated: Bool) {
        gateTimeout = gated ? .seconds(1) : .never
        if !gated { open() }
    }

    func run(_ args: [String]) -> Data? {
        lock.withLock { calls.append((args, Thread.isMainThread)) }
        _ = gate.wait(timeout: .now() + gateTimeout)
        gate.signal() // an open gate stays open for the next caller
        lock.withLock { finished += 1 }
        return args.first == "list" ? Self.list : Self.info(args.last ?? "")
    }

    func open() { gate.signal() }

    var started: Int { lock.withLock { calls.count } }
    var completed: Int { lock.withLock { finished } }
    var passes: Int { lock.withLock { calls.filter { $0.args.first == "list" }.count } }
    var callsOnMainThread: Int { lock.withLock { calls.filter(\.onMain).count } }

    private static func plist(_ object: Any) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    static let list = plist([
        "AllDisksAndPartitions": [[
            "DeviceIdentifier": "disk5",
            "Size": 8_000_000_000,
            "Content": "FDisk_partition_scheme",
            "Partitions": [[
                "DeviceIdentifier": "disk5s1",
                "Size": 7_999_000_000,
                "Content": "",
            ]],
        ]],
    ])

    static func info(_ bsd: String) -> Data {
        plist(["Removable": true, "Internal": false, "Ejectable": true, "DeviceIdentifier": bsd])
    }
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

@Suite("RawDisksModel")
@MainActor
struct RawDisksModelTests {

    @Test func aSlowPassLeavesTheMainActorFree() async {
        let diskutil = FakeDiskutil(gated: true)
        let model = RawDisksModel(runDiskutil: diskutil.run)

        model.refresh()
        #expect(diskutil.completed == 0, "refresh() waited for diskutil before returning")

        #expect(await eventually { diskutil.started >= 1 })
        #expect(diskutil.completed == 0, "the main actor only ran once diskutil had finished")

        diskutil.open()
        #expect(await eventually { !model.disks.isEmpty })
        #expect(diskutil.callsOnMainThread == 0)
    }

    @Test func refreshesDuringAPassDoNotQueueMorePasses() async {
        let diskutil = FakeDiskutil(gated: true)
        let model = RawDisksModel(runDiskutil: diskutil.run)

        for _ in 0..<5 { model.refresh() }
        #expect(await eventually { diskutil.started >= 1 })
        diskutil.open()
        #expect(await eventually { !model.disks.isEmpty })
        try? await Task.sleep(for: .milliseconds(100))

        #expect(diskutil.passes == 1)
    }

    @Test func aRefreshAfterAPassHasFinishedStartsANewOne() async {
        let diskutil = FakeDiskutil(gated: false)
        let model = RawDisksModel(runDiskutil: diskutil.run)

        model.refresh()
        #expect(await eventually { diskutil.completed == 3 && !model.disks.isEmpty })
        model.refresh()

        #expect(await eventually { diskutil.passes == 2 })
    }

    @Test func thePassPublishesTheParsedDiskTree() async {
        let diskutil = FakeDiskutil(gated: false)
        let model = RawDisksModel(runDiskutil: diskutil.run)

        model.refresh()
        #expect(await eventually { !model.disks.isEmpty })

        #expect(model.disks.map(\.bsdName) == ["disk5", "disk5s1"])
        #expect(model.disks.map(\.parentBsdName) == [nil, "disk5"])
        #expect(model.disks.allSatisfy { $0.isRemovable && $0.isEjectable && !$0.isInternal })
        #expect(model.formatableDisks.map(\.bsdName) == ["disk5"])
    }
}
