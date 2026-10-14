//
// MountedVolumeCheckTests.swift — how the host asks for a check of a volume
// that is already mounted (diskjockey#348).
//
// Verify on a mounted ext4 volume ran `fsck_fskit -t ext4 /dev/diskN`.
// FSKit serves a check task in a new extension instance that opens the
// device again, and with the volume mounted that open is refused EBUSY
// ("fsck_fskit: Operation ended with error: Resource busy") before the
// extension sees the task. The instance that holds the mount is reached
// through the App Group instead, by the request a repair already uses,
// now saying which operation it asks for.
//

import Foundation
import Testing
@testable import DiskJockeyLibrary

@Suite("A check of a mounted volume reaches the instance that mounted it (#348)")
struct MountedVolumeCheckTests {

    @Test("verify on a mounted ext4 volume is a request to the mounted instance, never fsck_fskit",
          arguments: ["ext4", "ext3", "ext2"])
    func ext4VerifyIsARequest(fsType: String) {
        #expect(MountedVolumeCheckRoute(fsType: fsType) == .request,
                "fsck_fskit opens the mounted device a second time and FSKit refuses it EBUSY")
    }

    @Test("a verify request says it is a verify, across the App Group")
    func verifyRequestRoundTrips() throws {
        let request = RepairRequest(bsd: "disk9", operation: .verify)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(RepairRequest.self, from: encoder.encode(request))

        #expect(decoded == request)
        #expect(decoded.operation == .verify)
    }

    @Test("a request that names no operation is a repair, as every request was before verify used them")
    func requestWithoutOperationIsARepair() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","bsd":"disk9","submittedAt":"2026-10-12T13:20:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(RepairRequest.self, from: Data(json.utf8))

        #expect(decoded.id == id)
        #expect(decoded.bsd == "disk9")
        #expect(decoded.operation == .repair)
    }

    @Test("a request built without an operation is a repair, so the Repair button's request is unchanged")
    func defaultOperationIsRepair() {
        #expect(RepairRequest(bsd: "disk9").operation == .repair)
    }
}
