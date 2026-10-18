import Foundation

/// The authority returned by attach, never inferred from the image's format
/// or a slice's BSD name when the user later ejects it.
public enum ImageEjectAttachment: Hashable, Sendable {
    case driverKit(UInt64)
    case hdiutil(String)
}

/// Retains the attachment behind every mounted sibling volume (#480).
/// The app supplies XPC calls. Owned DriverKit detach already unmounts the
/// whole attachment before removing its media and reader; hdiutil detach
/// performs the corresponding unmount/removal for its own image route.
@MainActor
public final class ImageEjectSequence {
    private var byDevice: [String: ImageEjectAttachment] = [:]
    private var byMountPath: [String: ImageEjectAttachment] = [:]
    private var pending: [ImageEjectAttachment: Task<Void, Error>] = [:]

    public init() {}

    public func register(attachment: ImageEjectAttachment, devices: [String], mountPaths: [String]) {
        for device in devices { byDevice[Self.bsdName(device)] = attachment }
        for mountPath in mountPaths { byMountPath[mountPath] = attachment }
    }

    /// False means this is not one of our image mounts: keep the caller's
    /// ordinary volume unmount/eject. Failure retains the route for retry,
    /// without falling back from an owned identity to an hdiutil BSD name.
    @discardableResult
    public func eject(
        mountPath: String, device: String? = nil,
        detachDriverKit: @escaping (UInt64) async throws -> Void,
        detachHdiutil: @escaping (String) async throws -> Void
    ) async throws -> Bool {
        // A supplied current device takes precedence over a stale mount path.
        let attachment: ImageEjectAttachment?
        if let device { attachment = byDevice[Self.bsdName(device)] }
        else { attachment = byMountPath[mountPath] }
        guard let attachment else { return false }
        if let task = pending[attachment] {
            try await task.value
            return true
        }
        let task = Task {
            switch attachment {
            case .driverKit(let identity): try await detachDriverKit(identity)
            case .hdiutil(let parent): try await detachHdiutil(parent)
            }
        }
        pending[attachment] = task
        do {
            try await task.value
            // Eject removes the whole image, including every sibling slice.
            byDevice = byDevice.filter { $0.value != attachment }
            byMountPath = byMountPath.filter { $0.value != attachment }
            pending[attachment] = nil
            return true
        } catch {
            pending[attachment] = nil
            throw error
        }
    }

    private static func bsdName(_ device: String) -> String {
        device.hasPrefix("/dev/") ? String(device.dropFirst(5)) : device
    }
}
