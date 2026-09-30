import Foundation
import OSLog
import ServiceManagement

private let logger = Logger(subsystem: "com.antimatterstudios.diskjockey", category: "DJAgentClient")

@MainActor
final class DJAgentClient {
    static let shared = DJAgentClient()

    private var connection: NSXPCConnection?

    // NOTE: an UNSANDBOXED agent cannot be registered by this sandboxed app
    // via SMAppService (BTM rejects it: "target executable must be sandboxed
    // because the app is sandboxed"), and it can't ship through the Mac App
    // Store at all. Extension enable-state is now read in-app via FSKit's
    // `FSClient` (see ExtensionStateService) — no agent needed for that. The
    // agent remains a dev-only helper (loaded via scripts/install-agent-dev.sh)
    // for disk-image probing. This call is a harmless no-op when no agent is
    // registered (status `.notFound`).
    static func register() {
        let svc = SMAppService.agent(plistName: "com.antimatterstudios.diskjockey.agent.plist")
        do {
            if svc.status == .notRegistered {
                try svc.register()
            }
        } catch {
            logger.error("SMAppService agent registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Attach through the agent, sending the image opened for reading as
    /// proof that this app may read it (diskjockey#94). The agent is
    /// unsandboxed; the open is what keeps it from attaching anything this
    /// app's sandbox would not have let it read itself.
    func attachImage(atPath path: String, imageURL: URL? = nil) async throws -> FSKitMountService.HdiutilAttachResult {
        let proof: FileHandle
        do {
            proof = try FileHandle(forReadingFrom: imageURL ?? URL(fileURLWithPath: path))
        } catch {
            throw FSKitMountService.FSKitError.processFailed(
                exitCode: -1,
                stderr: "cannot open \(path) for reading, and the agent attaches only an image this app can read: \(error.localizedDescription)")
        }
        let proxy: DJAgentProtocol
        do { proxy = try makeProxy() } catch { try? proof.close(); throw error }
        return try await withCheckedThrowingContinuation { continuation in
            proxy.attachImage(atPath: path, proof: proof) { slices, error in
                try? proof.close()
                if let errorMsg = error {
                    continuation.resume(throwing: FSKitMountService.FSKitError.processFailed(
                        exitCode: -1, stderr: errorMsg))
                    return
                }
                guard let devEntries = slices else {
                    continuation.resume(throwing: FSKitMountService.FSKitError.processFailed(
                        exitCode: -1, stderr: "agent returned nil slices"))
                    return
                }
                var parent: String?
                var sliceList: [String] = []
                for dev in devEntries {
                    if dev.range(of: #"^/dev/disk\d+$"#, options: .regularExpression) != nil {
                        parent = dev
                    } else if dev.range(of: #"^/dev/disk\d+s\d+$"#, options: .regularExpression) != nil {
                        sliceList.append(dev)
                    }
                }
                guard let parentDevice = parent else {
                    continuation.resume(throwing: FSKitMountService.FSKitError.processFailed(
                        exitCode: -1, stderr: "agent returned no parent /dev/diskN"))
                    return
                }
                continuation.resume(returning: FSKitMountService.HdiutilAttachResult(
                    parentDevice: parentDevice,
                    slices: sliceList))
            }
        }
    }

    func probeImage(atPath path: String) async throws -> DiskProbeResult {
        let proxy = try makeProxy()
        return try await withCheckedThrowingContinuation { continuation in
            proxy.probeImage(atPath: path) { json, error in
                if let errorMsg = error {
                    continuation.resume(throwing: FSKitMountService.FSKitError.processFailed(
                        exitCode: -1, stderr: errorMsg))
                    return
                }
                guard let json, let data = json.data(using: .utf8) else {
                    continuation.resume(throwing: FSKitMountService.FSKitError.processFailed(
                        exitCode: -1, stderr: "agent returned empty probe result"))
                    return
                }
                do {
                    continuation.resume(returning: try JSONDecoder().decode(DiskProbeResult.self, from: data))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func detachDevice(_ bsdName: String) async throws {
        let proxy = try makeProxy()
        try await callAgent(fallbackError: "agent detach failed") { cb in
            proxy.detachDevice(bsdName, reply: cb)
        }
    }

    func mountFSKit(source: String, mountPoint: String, fsType: String,
                    partitionOffset: Int64 = 0, partitionLength: Int64 = 0) async throws {
        let proxy = try makeProxy()
        try await callAgent(fallbackError: "agent mountFSKit failed") { cb in
            proxy.mountFSKit(source: source, mountPoint: mountPoint, fsType: fsType,
                             partitionOffset: partitionOffset, partitionLength: partitionLength, reply: cb)
        }
    }

    private func callAgent(fallbackError: String,
                           body: @escaping (@escaping (Bool, String?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            body { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: FSKitMountService.FSKitError.processFailed(
                        exitCode: -1, stderr: error ?? fallbackError))
                }
            }
        }
    }

    /// What the agent must prove before this app will talk to it.
    ///
    /// The agent checks US — `DiskJockeyAgent/main.swift` pins a
    /// requirement on every incoming connection — and until now nothing
    /// checked IT. Authentication in one direction is not
    /// authentication: the mach name
    /// `com.antimatterstudios.diskjockey.agent` is registered from
    /// `~/Library/LaunchAgents`, which the user can write to without
    /// authorisation, so any process running as the user could claim
    /// the name and receive `attachImage(atPath:)`,
    /// `detachDevice(_:)` and `mountFSKit(...)` from a sandboxed app
    /// that believed it was talking to its own helper.
    ///
    /// `anchor apple generic` is the half that does the work: it
    /// requires an Apple-issued certificate chain, which a locally
    /// produced binary cannot forge. The team check then narrows that
    /// to our own signing identity.
    ///
    /// The agent's code-signing IDENTIFIER is deliberately not pinned.
    /// It is not a committed Xcode target — it is built by
    /// `scripts/install-agent-dev.sh` from DerivedData — so its
    /// identifier is not fixed anywhere this code can read, and pinning
    /// a guess would fail closed: the connection would be invalidated
    /// with no error at the call site, which is worse than the gap
    /// being fixed. Tighten this the day the agent becomes a real
    /// target.
    ///
    /// The team ID is also spelled in `DiskJockeyAgent/main.swift` as
    /// `kTeamID`. Two copies, because the agent is not an Xcode target
    /// and shares no compilation unit with the app — if one is ever
    /// changed without the other, the app and its helper stop being
    /// able to talk and neither says why. Change both.
    private static let teamID = "43UMKXZ8P4"

    private static var agentRequirement: String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    private func makeProxy() throws -> DJAgentProtocol {
        if connection == nil {
            let conn = NSXPCConnection(machServiceName: "com.antimatterstudios.diskjockey.agent",
                                       options: [])
            // Before anything is sent, and before the interface is set:
            // a connection that cannot prove who it is should never
            // carry a message.
            conn.setCodeSigningRequirement(Self.agentRequirement)
            conn.remoteObjectInterface = NSXPCInterface(with: DJAgentProtocol.self)
            conn.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            conn.resume()
            connection = conn
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            Task { @MainActor in self?.connection = nil }
        }) as? DJAgentProtocol else {
            throw FSKitMountService.FSKitError.processFailed(
                exitCode: -1, stderr: "failed to obtain DJAgent proxy")
        }
        return proxy
    }
}
