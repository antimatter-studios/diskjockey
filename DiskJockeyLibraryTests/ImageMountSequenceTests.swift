//
//  ImageMountSequenceTests.swift — what each attachment route does between
//  attaching an image and handing its partitions to Disk Arbitration
//  (diskjockey#479).
//
//  The DriverKit route attaches through the agent once, waits for the
//  attachment's media, and mounts each selected partition read-only. Any
//  mount failure, or media that never appears, detaches exactly once so no
//  owned attachment survives. The hdiutil route keeps its read-write mounts
//  and its partial successes.
//
//  Host-free: the steps are fakes that record what they were asked to do.
//

import Testing
@testable import DiskJockeyLibrary

private struct Refused: Error {}

@MainActor
private final class FakeSteps {
    var attachCount = 0
    var detached: [String] = []
    var mounts: [(device: String, readOnly: Bool)] = []
    var failingDevices: Set<String> = []
    var mediaAppears = true

    func steps() -> ImageMountSteps<String, String> {
        ImageMountSteps(
            attach: { self.attachCount += 1; return "disk9" },
            waitForPartitions: { whole, indices in
                guard self.mediaAppears else { throw Refused() }
                return Dictionary(uniqueKeysWithValues: indices.map { ($0, "\(whole)s\($0 + 1)") })
            },
            mount: { device, readOnly in
                self.mounts.append((device, readOnly))
                if self.failingDevices.contains(device) { throw Refused() }
                return "/Volumes/\(device)"
            },
            detach: { self.detached.append($0) },
            wholeDisk: { whole in
                guard self.mediaAppears else { throw Refused() }
                return whole
            })
    }
}

@MainActor
@Suite("Image mount sequence")
struct ImageMountSequenceTests {
    // A bare filesystem in a qcow2 or VHDX image has no partition table, so
    // the DriverKit route mounts its whole media, read-only, and detaches
    // exactly once when that media never appears or its mount is refused
    // (diskjockey#515).
    @Test func driverKitMountsABareFilesystemsWholeDiskReadOnly() async throws {
        let fake = FakeSteps()
        let volume = try await ImageMountSequence.runWholeDisk(route: .driverKit, steps: fake.steps())
        #expect(fake.attachCount == 1)
        #expect(fake.mounts.map(\.device) == ["disk9"])
        #expect(fake.mounts.allSatisfy { $0.readOnly })
        #expect(volume == "/Volumes/disk9")
        #expect(fake.detached.isEmpty)
    }

    @Test func driverKitDetachesOnceWhenTheWholeDiskNeverAppears() async {
        let fake = FakeSteps()
        fake.mediaAppears = false
        await #expect(throws: Refused.self) {
            _ = try await ImageMountSequence.runWholeDisk(route: .driverKit, steps: fake.steps())
        }
        #expect(fake.attachCount == 1)
        #expect(fake.mounts.isEmpty)
        #expect(fake.detached == ["disk9"])
    }

    @Test func driverKitDetachesOnceWhenTheWholeDiskMountFails() async {
        let fake = FakeSteps()
        fake.failingDevices = ["disk9"]
        await #expect(throws: Refused.self) {
            _ = try await ImageMountSequence.runWholeDisk(route: .driverKit, steps: fake.steps())
        }
        #expect(fake.attachCount == 1)
        #expect(fake.detached == ["disk9"])
    }

    @Test func hdiutilMountsABareFilesystemsWholeDiskReadWrite() async throws {
        let fake = FakeSteps()
        let volume = try await ImageMountSequence.runWholeDisk(route: .hdiutil, steps: fake.steps())
        #expect(fake.mounts.map(\.device) == ["disk9"])
        #expect(fake.mounts.allSatisfy { !$0.readOnly })
        #expect(volume == "/Volumes/disk9")
        #expect(fake.detached.isEmpty)
    }

    @Test func aWholeDiskWithNoRouteAttachesNothing() async {
        let fake = FakeSteps()
        await #expect(throws: ImageMountSequence.Unsupported.self) {
            _ = try await ImageMountSequence.runWholeDisk(route: .unsupported, steps: fake.steps())
        }
        #expect(fake.attachCount == 0)
    }

    @Test func driverKitAttachesOnceAndMountsEachSelectedPartitionReadOnly() async throws {
        let fake = FakeSteps()
        let volumes = try await ImageMountSequence.run(route: .driverKit, partitions: [0, 2],
                                                       steps: fake.steps())
        #expect(fake.attachCount == 1)
        #expect(fake.mounts.map(\.device) == ["disk9s1", "disk9s3"])
        #expect(fake.mounts.allSatisfy { $0.readOnly })
        #expect(volumes == ["/Volumes/disk9s1", "/Volumes/disk9s3"])
        #expect(fake.detached.isEmpty)
    }

    // An APFS partition beside an ext4 one on a qcow2 image: both are
    // selected, and the APFS one mounts read-only like the rest of the
    // DriverKit route (diskjockey#486).
    @Test func driverKitMountsAnAppleFilesystemPartitionReadOnly() async throws {
        let route = ImageAttachmentRoute(container: "qcow2")
        let kinds = ["ext4", "apfs"]
        #expect(kinds.map(route.mountType(forProbeKind:)) == ["ext4", "apfs"])
        let selected = kinds.indices.filter { route.mountType(forProbeKind: kinds[$0]) != nil }
        let fake = FakeSteps()
        let volumes = try await ImageMountSequence.run(route: route, partitions: selected,
                                                       steps: fake.steps())
        #expect(fake.mounts.map(\.device) == ["disk9s1", "disk9s2"])
        #expect(fake.mounts.allSatisfy { $0.readOnly })
        #expect(volumes.count == 2)
        #expect(fake.detached.isEmpty)
    }

    @Test func driverKitDetachesOnceWhenAMountFails() async {
        let fake = FakeSteps()
        fake.failingDevices = ["disk9s1"]
        await #expect(throws: Refused.self) {
            _ = try await ImageMountSequence.run(route: .driverKit, partitions: [0, 1],
                                                 steps: fake.steps())
        }
        #expect(fake.attachCount == 1)
        #expect(fake.detached == ["disk9"])
    }

    @Test func driverKitDetachesOnceWhenALaterMountFails() async {
        let fake = FakeSteps()
        fake.failingDevices = ["disk9s2"]
        await #expect(throws: Refused.self) {
            _ = try await ImageMountSequence.run(route: .driverKit, partitions: [0, 1],
                                                 steps: fake.steps())
        }
        #expect(fake.detached == ["disk9"])
    }

    @Test func driverKitDetachesOnceWhenMediaNeverAppears() async {
        let fake = FakeSteps()
        fake.mediaAppears = false
        await #expect(throws: Refused.self) {
            _ = try await ImageMountSequence.run(route: .driverKit, partitions: [0],
                                                 steps: fake.steps())
        }
        #expect(fake.attachCount == 1)
        #expect(fake.mounts.isEmpty)
        #expect(fake.detached == ["disk9"])
    }

    @Test func hdiutilMountsReadWriteAndKeepsPartialSuccesses() async throws {
        let fake = FakeSteps()
        fake.failingDevices = ["disk9s1"]
        let volumes = try await ImageMountSequence.run(route: .hdiutil, partitions: [0, 1],
                                                       steps: fake.steps())
        #expect(fake.attachCount == 1)
        #expect(fake.mounts.allSatisfy { !$0.readOnly })
        #expect(volumes == ["/Volumes/disk9s2"])
        #expect(fake.detached.isEmpty)
    }

    @Test func hdiutilDetachesOnceWhenEveryMountFails() async throws {
        let fake = FakeSteps()
        fake.failingDevices = ["disk9s1", "disk9s2"]
        let volumes = try await ImageMountSequence.run(route: .hdiutil, partitions: [0, 1],
                                                       steps: fake.steps())
        #expect(volumes.isEmpty)
        #expect(fake.detached == ["disk9"])
    }

    @Test func unsupportedRouteAttachesNothing() async {
        let fake = FakeSteps()
        await #expect(throws: ImageMountSequence.Unsupported.self) {
            _ = try await ImageMountSequence.run(route: .unsupported, partitions: [0],
                                                 steps: fake.steps())
        }
        #expect(fake.attachCount == 0)
        #expect(fake.detached.isEmpty)
    }
}
