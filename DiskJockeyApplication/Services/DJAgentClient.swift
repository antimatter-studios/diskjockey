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

    func attachImage(atPath path: String) async throws -> FSKitMountService.HdiutilAttachResult {
        let proxy = try makeProxy()
        return try await withCheckedThrowingContinuation { continuation in
            proxy.attachImage(atPath: path) { slices, error in
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

    /// Per-extension enable state, read by the unsandboxed agent via
    /// pluginkit. Keyed by the bundle ids passed in; ids the agent couldn't
    /// determine are simply absent from the result.
    func extensionStates(forBundleIDs ids: [String]) async throws -> [String: Bool] {
        let proxy = try makeProxy()
        return try await withCheckedThrowingContinuation { continuation in
            proxy.extensionStates(forBundleIDs: ids) { json, error in
                if let errorMsg = error {
                    continuation.resume(throwing: FSKitMountService.FSKitError.processFailed(
                        exitCode: -1, stderr: errorMsg))
                    return
                }
                guard let json, let data = json.data(using: .utf8),
                      let map = try? JSONDecoder().decode([String: Bool].self, from: data) else {
                    continuation.resume(throwing: FSKitMountService.FSKitError.processFailed(
                        exitCode: -1, stderr: "agent returned no extension states"))
                    return
                }
                continuation.resume(returning: map)
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

    private func makeProxy() throws -> DJAgentProtocol {
        if connection == nil {
            let conn = NSXPCConnection(machServiceName: "com.antimatterstudios.diskjockey.agent",
                                       options: [])
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
