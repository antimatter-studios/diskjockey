import Foundation

/// A device and its opaque agent identity travel together through mount cleanup.
/// The agent binds this identity to the live connection that created it.
@MainActor
struct DriverKitImageAttachment {
    let attachmentID: UInt64
    let device: String

    static func attach(imageURL: URL, offset: UInt64 = 0, length: UInt64 = 0,
                       blockSize: UInt32 = 0) async throws -> Self {
        let (identity, device) = try await DJAgentClient.shared.attachDriverKitImage(
            atPath: imageURL.path, imageURL: imageURL, offset: offset, length: length, blockSize: blockSize)
        return Self(attachmentID: identity, device: device)
    }

    func detach() async throws {
        try await DJAgentClient.shared.detachDriverKitImage(attachmentID)
    }
}
