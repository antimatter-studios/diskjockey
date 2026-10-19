import Testing
@testable import DiskJockeyLibrary

private struct EjectRefused: Error {}

@MainActor
private final class EjectCalls {
    var owned: [UInt64] = []
    var hdiutil: [String] = []
    var refuses = false

    func detachOwned(_ identity: UInt64) async throws {
        owned.append(identity)
        if refuses { throw EjectRefused() }
    }

    func detachHdiutil(_ device: String) async throws {
        hdiutil.append(device)
        if refuses { throw EjectRefused() }
    }

    func eject(_ sequence: ImageEjectSequence, path: String, device: String? = nil) async throws -> Bool {
        try await sequence.eject(mountPath: path, device: device,
                                 detachDriverKit: detachOwned, detachHdiutil: detachHdiutil)
    }
}

@MainActor
@Suite("Image eject sequence")
struct ImageEjectSequenceTests {
    @Test func driverKitEjectUsesOwnedIdentityOnceForAllSiblingVolumes() async throws {
        let sequence = ImageEjectSequence()
        let calls = EjectCalls()
        sequence.register(attachment: .driverKit(480), devices: ["disk9s1", "disk9s2"],
                          mountPaths: ["/Volumes/first", "/Volumes/second"])
        #expect(try await calls.eject(sequence, path: "/Volumes/second"))
        #expect(try await !calls.eject(sequence, path: "/Volumes/first"))
        #expect(calls.owned == [480])
        #expect(calls.hdiutil.isEmpty)
    }

    @Test func hdiutilEjectStillDetachesItsParentDevice() async throws {
        let sequence = ImageEjectSequence()
        let calls = EjectCalls()
        sequence.register(attachment: .hdiutil("/dev/disk7"), devices: ["/dev/disk7s1"],
                          mountPaths: ["/Volumes/raw"])
        #expect(try await calls.eject(sequence, path: "/Volumes/raw"))
        #expect(calls.hdiutil == ["/dev/disk7"])
        #expect(calls.owned.isEmpty)
    }

    @Test func anUnregisteredVolumeUsesNeitherImageDetach() async throws {
        let sequence = ImageEjectSequence()
        let calls = EjectCalls()
        #expect(try await !calls.eject(sequence, path: "/Volumes/physical", device: "disk2s1"))
        #expect(calls.owned.isEmpty)
        #expect(calls.hdiutil.isEmpty)
    }

    @Test func failedOwnedDetachKeepsIdentityForRetryWithoutHdiutilFallback() async throws {
        let sequence = ImageEjectSequence()
        let calls = EjectCalls()
        sequence.register(attachment: .driverKit(481), devices: ["disk9s1"], mountPaths: ["/Volumes/image"])
        calls.refuses = true
        await #expect(throws: EjectRefused.self) { try await calls.eject(sequence, path: "/Volumes/image") }
        calls.refuses = false
        #expect(try await calls.eject(sequence, path: "/Volumes/image"))
        #expect(calls.owned == [481, 481])
        #expect(calls.hdiutil.isEmpty)
    }

    @Test func failedHdiutilDetachKeepsItsRouteForRetry() async throws {
        let sequence = ImageEjectSequence()
        let calls = EjectCalls()
        sequence.register(attachment: .hdiutil("/dev/disk7"), devices: ["disk7s1"], mountPaths: ["/Volumes/raw"])
        calls.refuses = true
        await #expect(throws: EjectRefused.self) { try await calls.eject(sequence, path: "/Volumes/raw") }
        calls.refuses = false
        #expect(try await calls.eject(sequence, path: "/Volumes/raw"))
        #expect(calls.hdiutil == ["/dev/disk7", "/dev/disk7"])
        #expect(calls.owned.isEmpty)
    }

    @Test func deviceLookupWorksWhenMountDidNotReportAPath() async throws {
        let sequence = ImageEjectSequence()
        let calls = EjectCalls()
        sequence.register(attachment: .driverKit(482), devices: ["/dev/disk9s1"], mountPaths: [])
        #expect(try await calls.eject(sequence, path: "/Volumes/later", device: "disk9s1"))
        #expect(calls.owned == [482])
    }

    @Test func simultaneousSiblingEjectsShareOneOwnedDetach() async throws {
        let sequence = ImageEjectSequence()
        sequence.register(attachment: .driverKit(483), devices: ["disk9s1", "disk9s2"],
                          mountPaths: ["/Volumes/first", "/Volumes/second"])
        var identities: [UInt64] = []
        var finish: CheckedContinuation<Void, Never>?
        let detach: (UInt64) async throws -> Void = { identity in
            identities.append(identity)
            await withCheckedContinuation { finish = $0 }
        }
        let first = Task { try await sequence.eject(mountPath: "/Volumes/first",
            detachDriverKit: detach, detachHdiutil: { _ in Issue.record("wrong route") }) }
        while finish == nil { await Task.yield() }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return try await sequence.eject(mountPath: "/Volumes/second",
                detachDriverKit: detach, detachHdiutil: { _ in Issue.record("wrong route") })
        }
        while !secondStarted { await Task.yield() }
        finish?.resume()
        #expect(try await first.value)
        #expect(try await second.value)
        #expect(identities == [483])
    }

    @Test func aReusedMountPathDoesNotDetachAnOlderImagesAttachment() async throws {
        let sequence = ImageEjectSequence()
        let calls = EjectCalls()
        sequence.register(attachment: .driverKit(485), devices: ["disk9s1"], mountPaths: ["/Volumes/reused"])
        #expect(try await !calls.eject(sequence, path: "/Volumes/reused", device: "disk10s1"))
        #expect(calls.owned.isEmpty)
        #expect(calls.hdiutil.isEmpty)
    }

    @Test func ejectingOneImageKeepsOtherImagesRegistered() async throws {
        let sequence = ImageEjectSequence()
        let calls = EjectCalls()
        sequence.register(attachment: .driverKit(484), devices: ["disk9s1"], mountPaths: ["/Volumes/a"])
        sequence.register(attachment: .hdiutil("/dev/disk8"), devices: ["disk8s1"], mountPaths: ["/Volumes/b"])
        #expect(try await calls.eject(sequence, path: "/Volumes/a"))
        #expect(try await calls.eject(sequence, path: "/Volumes/b"))
        #expect(calls.owned == [484])
        #expect(calls.hdiutil == ["/dev/disk8"])
    }
}
