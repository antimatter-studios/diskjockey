import Foundation
import OSLog
import ServiceManagement

private let logger = Logger(subsystem: "com.antimatterstudios.diskjockey", category: "DJAgentClient")

@MainActor
final class DJAgentClient {
    static let shared = DJAgentClient()

    private var connection: NSXPCConnection?

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

    func detachDevice(_ bsdName: String) async throws {
        let proxy = try makeProxy()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.detachDevice(bsdName) { success, error in
                if success {
                    continuation.resume()
                } else {
                    let msg = error ?? "agent detach failed"
                    continuation.resume(throwing: FSKitMountService.FSKitError.processFailed(
                        exitCode: -1, stderr: msg))
                }
            }
        }
    }

    func mountFSKit(source: String, mountPoint: String, fsType: String,
                    partitionOffset: Int64 = 0, partitionLength: Int64 = 0) async throws {
        let proxy = try makeProxy()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.mountFSKit(source: source, mountPoint: mountPoint, fsType: fsType,
                             partitionOffset: partitionOffset, partitionLength: partitionLength) { success, error in
                if success {
                    continuation.resume()
                } else {
                    let msg = error ?? "agent mountFSKit failed"
                    continuation.resume(throwing: FSKitMountService.FSKitError.processFailed(
                        exitCode: -1, stderr: msg))
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
