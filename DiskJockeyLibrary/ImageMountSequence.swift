//
// ImageMountSequence.swift — what happens between attaching a disk image and
// handing its partitions to Disk Arbitration, per attachment route.
//
// The hdiutil route mounts each slice read-write and keeps whatever mounted;
// it detaches only when nothing did. The DriverKit route attaches through the
// agent, which owns the attachment for the app's connection. It mounts each
// selected partition read-only, and any failure — media that never appears,
// or one mount refused — detaches exactly once and throws, so no owned
// attachment survives a half-finished mount (diskjockey#479).
//
// The steps are closures so the app supplies the agent and Disk Arbitration
// and the tests supply fakes.
//

import Foundation

public struct ImageMountSteps<Attachment, Volume> {
    /// Attach the image and return what `detach` later needs.
    public var attach: () async throws -> Attachment
    /// Wait for the attachment's partitions; partition index to BSD name.
    public var waitForPartitions: (Attachment, [Int]) async throws -> [Int: String]
    /// Mount one partition through Disk Arbitration.
    public var mount: (_ device: String, _ readOnly: Bool) async throws -> Volume
    public var detach: (Attachment) async -> Void

    public init(attach: @escaping () async throws -> Attachment,
                waitForPartitions: @escaping (Attachment, [Int]) async throws -> [Int: String],
                mount: @escaping (_ device: String, _ readOnly: Bool) async throws -> Volume,
                detach: @escaping (Attachment) async -> Void) {
        self.attach = attach
        self.waitForPartitions = waitForPartitions
        self.mount = mount
        self.detach = detach
    }
}

@MainActor
public enum ImageMountSequence {
    public struct Unsupported: Error {}

    public static func run<Attachment, Volume>(
        route: ImageAttachmentRoute, partitions: [Int],
        steps: ImageMountSteps<Attachment, Volume>
    ) async throws -> [Volume] {
        switch route {
        case .unsupported: throw Unsupported()
        case .hdiutil:     return try await mountKeepingSuccesses(partitions, steps)
        case .driverKit:   return try await mountAllReadOnly(partitions, steps)
        }
    }

    private static func mountKeepingSuccesses<Attachment, Volume>(
        _ partitions: [Int], _ steps: ImageMountSteps<Attachment, Volume>
    ) async throws -> [Volume] {
        let attachment = try await steps.attach()
        let devices: [Int: String]
        do { devices = try await steps.waitForPartitions(attachment, partitions) }
        catch { await steps.detach(attachment); throw error }
        var mounted: [Volume] = []
        for index in partitions {
            guard let device = devices[index] else { continue }
            if let volume = try? await steps.mount(device, false) { mounted.append(volume) }
        }
        if mounted.isEmpty { await steps.detach(attachment) }
        return mounted
    }

    private static func mountAllReadOnly<Attachment, Volume>(
        _ partitions: [Int], _ steps: ImageMountSteps<Attachment, Volume>
    ) async throws -> [Volume] {
        let attachment = try await steps.attach()
        do {
            let devices = try await steps.waitForPartitions(attachment, partitions)
            var mounted: [Volume] = []
            for index in partitions {
                guard let device = devices[index] else { throw MissingPartition(index: index) }
                mounted.append(try await steps.mount(device, true))
            }
            return mounted
        } catch {
            await steps.detach(attachment)
            throw error
        }
    }

    public struct MissingPartition: Error { public let index: Int }
}
