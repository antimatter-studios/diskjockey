import Foundation
import SwiftProtobuf

public class HelperAPI {
    private let socket: TCPSocket

    public init(socket: TCPSocket) {
        self.socket = socket
    }

    public func shutdown(completion: @escaping (Result<Api_ShutdownResponse, Error>) -> Void) {
        let typeId = Api_MessageType.shutdownRequest.rawValue
        let req = Api_ShutdownRequest()
        do {
            let requestData = try req.serializedData()
            let lenBuf = withUnsafeBytes(of: UInt32(requestData.count + 1).bigEndian, Array.init)
            var packet = Data()
            packet.append(contentsOf: lenBuf)
            packet.append(UInt8(typeId))
            packet.append(requestData)
            guard socket.send(packet) else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to send shutdown request over IPC."])));
                return
            }
            guard let respLenBuf = socket.receive(4), respLenBuf.count == 4 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to read shutdown response length."])));
                return
            }
            let respLen = Int(UInt32(bigEndian: respLenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
            guard let respTypeData = socket.receive(1), respTypeData.count == 1 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to read shutdown response type."])));
                return
            }
            let respType = respTypeData[0]
            if respType != typeId {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -5, userInfo: [NSLocalizedDescriptionKey: "Unexpected shutdown response type: \(respType)"])));
                return
            }
            guard let respBuf = socket.receive(respLen - 1), respBuf.count == respLen - 1 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to read shutdown response payload."])));
                return
            }
            do {
                var resp = Api_ShutdownResponse()
                try resp.merge(serializedData: respBuf)
                if !resp.success {
                    completion(.failure(NSError(domain: "DiskJockeyHelper", code: -7, userInfo: [NSLocalizedDescriptionKey: resp.message])));
                    return
                }
                completion(.success(resp))
            } catch {
                completion(.failure(error))
            }
        } catch {
            completion(.failure(error))
        }
    }

    public func createMount(name: String, pluginType: String, config: [String: String], completion: @escaping (Result<UInt32, Error>) -> Void) {
        var req = Api_CreateMountRequest()
        req.name = name
        req.pluginType = pluginType
        req.config = config
        let typeId = Api_MessageType.createMountRequest.rawValue
        do {
            let requestData = try req.serializedData()
            let lenBuf = withUnsafeBytes(of: UInt32(requestData.count + 1).bigEndian, Array.init)
            var packet = Data()
            packet.append(contentsOf: lenBuf)
            packet.append(UInt8(typeId))
            packet.append(requestData)
            guard socket.send(packet) else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to send create mount request over IPC."])));
                return
            }
            guard let respLenBuf = socket.receive(4), respLenBuf.count == 4 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to read create mount response length."])));
                return
            }
            let respLen = Int(UInt32(bigEndian: respLenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
            guard let respTypeData = socket.receive(1), respTypeData.count == 1 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to read create mount response type."])));
                return
            }
            let respType = respTypeData[0]
            if respType != typeId {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -5, userInfo: [NSLocalizedDescriptionKey: "Unexpected create mount response type: \(respType)"])));
                return
            }
            guard let respBuf = socket.receive(respLen - 1), respBuf.count == respLen - 1 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to read create mount response payload."])));
                return
            }
            do {
                var resp = Api_CreateMountResponse()
                try resp.merge(serializedData: respBuf)
                if !resp.error.isEmpty {
                    completion(.failure(NSError(domain: "DiskJockeyHelper", code: -7, userInfo: [NSLocalizedDescriptionKey: resp.error])));
                    return
                }
                completion(.success(resp.mountID))
            } catch {
                completion(.failure(error))
            }
        } catch {
            completion(.failure(error))
        }
    }

    public func deleteMount(mountID: UInt32, completion: @escaping (Result<Void, Error>) -> Void) {
        var req = Api_DeleteMountRequest()
        req.mountID = mountID
        let typeId = Api_MessageType.deleteMountRequest.rawValue // DeleteMountRequest type ID
        do {
            let requestData = try req.serializedData()
            let lenBuf = withUnsafeBytes(of: UInt32(requestData.count + 1).bigEndian, Array.init)
            var packet = Data()
            packet.append(contentsOf: lenBuf)
            packet.append(UInt8(typeId))
            packet.append(requestData)
            guard socket.send(packet) else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to send delete mount request over IPC."])));
                return
            }
            guard let respLenBuf = socket.receive(4), respLenBuf.count == 4 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to read delete mount response length."])));
                return
            }
            let respLen = Int(UInt32(bigEndian: respLenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
            guard let respTypeData = socket.receive(1), respTypeData.count == 1 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to read delete mount response type."])));
                return
            }
            let respType = respTypeData[0]
            if respType != typeId {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -5, userInfo: [NSLocalizedDescriptionKey: "Unexpected delete mount response type: \(respType)"])));
                return
            }
            guard let respBuf = socket.receive(respLen - 1), respBuf.count == respLen - 1 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to read delete mount response payload."])));
                return
            }
            do {
                var resp = Api_DeleteMountResponse()
                try resp.merge(serializedData: respBuf)
                if !resp.error.isEmpty {
                    completion(Result.failure(NSError(domain: "DiskJockeyHelper", code: -7, userInfo: [NSLocalizedDescriptionKey: resp.error])));
                    return
                }
                completion(Result.success(()))
            } catch {
                completion(Result.failure(error))
            }
        } catch {
            completion(.failure(error))
        }
    }

    public func mount(mountID: UInt32, completion: @escaping (Result<Void, Error>) -> Void) {
        var req = Api_MountRequest()
        req.mountID = mountID
        let typeId = Api_MessageType.mountRequest.rawValue
        do {
            let requestData = try req.serializedData()
            let lenBuf = withUnsafeBytes(of: UInt32(requestData.count + 1).bigEndian, Array.init)
            var packet = Data()
            packet.append(contentsOf: lenBuf)
            packet.append(UInt8(typeId))
            packet.append(requestData)
            guard socket.send(packet) else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to send mount request over IPC."])));
                return
            }
            guard let respLenBuf = socket.receive(4), respLenBuf.count == 4 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to read mount response length."])));
                return
            }
            let respLen = Int(UInt32(bigEndian: respLenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
            guard let respTypeData = socket.receive(1), respTypeData.count == 1 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to read mount response type."])));
                return
            }
            let respType = respTypeData[0]
            if respType != typeId {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -5, userInfo: [NSLocalizedDescriptionKey: "Unexpected mount response type: \(respType)"])));
                return
            }
            guard let respBuf = socket.receive(respLen - 1), respBuf.count == respLen - 1 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to read mount response payload."])));
                return
            }
            do {
                var resp = Api_MountResponse()
                try resp.merge(serializedData: respBuf)
                if !resp.error.isEmpty {
                    completion(.failure(NSError(domain: "DiskJockeyHelper", code: -7, userInfo: [NSLocalizedDescriptionKey: resp.error])));
                    return
                }
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        } catch {
            completion(.failure(error))
        }
    }

    public func unmount(mountID: UInt32, completion: @escaping (Result<Void, Error>) -> Void) {
        var req = Api_UnmountRequest()
        req.mountID = mountID
        let typeId = Api_MessageType.unmountRequest.rawValue
        do {
            let requestData = try req.serializedData()
            let lenBuf = withUnsafeBytes(of: UInt32(requestData.count + 1).bigEndian, Array.init)
            var packet = Data()
            packet.append(contentsOf: lenBuf)
            packet.append(UInt8(typeId))
            packet.append(requestData)
            guard socket.send(packet) else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to send unmount request over IPC."])));
                return
            }
            guard let respLenBuf = socket.receive(4), respLenBuf.count == 4 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to read unmount response length."])));
                return
            }
            let respLen = Int(UInt32(bigEndian: respLenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
            guard let respTypeData = socket.receive(1), respTypeData.count == 1 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to read unmount response type."])));
                return
            }
            let respType = respTypeData[0]
            if respType != typeId {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -5, userInfo: [NSLocalizedDescriptionKey: "Unexpected unmount response type: \(respType)"])));
                return
            }
            guard let respBuf = socket.receive(respLen - 1), respBuf.count == respLen - 1 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to read unmount response payload."])));
                return
            }
            do {
                var resp = Api_UnmountResponse()
                try resp.merge(serializedData: respBuf)
                if !resp.error.isEmpty {
                    completion(.failure(NSError(domain: "DiskJockeyHelper", code: -7, userInfo: [NSLocalizedDescriptionKey: resp.error])));
                    return
                }
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        } catch {
            completion(.failure(error))
        }
    }

    public func listMounts(completion: @escaping (Result<[Api_MountInfo], Error>) -> Void) {
        let typeId = Api_MessageType.listMountsRequest.rawValue
        let req = Api_ListMountsRequest()
        do {
            let requestData = try req.serializedData()
            let lenBuf = withUnsafeBytes(of: UInt32(requestData.count + 1).bigEndian, Array.init)
            var packet = Data()
            packet.append(contentsOf: lenBuf)
            packet.append(UInt8(typeId))
            packet.append(requestData)
            guard socket.send(packet) else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to send list mounts request over IPC."])));
                return
            }
            guard let respLenBuf = socket.receive(4), respLenBuf.count == 4 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to read list mounts response length."])));
                return
            }
            let respLen = Int(UInt32(bigEndian: respLenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
            guard let respTypeData = socket.receive(1), respTypeData.count == 1 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to read list mounts response type."])));
                return
            }
            let respType = respTypeData[0]
            if respType != typeId {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -5, userInfo: [NSLocalizedDescriptionKey: "Unexpected list mounts response type: \(respType)"])));
                return
            }
            guard let respBuf = socket.receive(respLen - 1), respBuf.count == respLen - 1 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to read list mounts response payload."])));
                return
            }
            do {
                var resp = Api_ListMountsResponse()
                try resp.merge(serializedData: respBuf)
                if !resp.error.isEmpty {
                    completion(.failure(NSError(domain: "DiskJockeyHelper", code: -7, userInfo: [NSLocalizedDescriptionKey: resp.error])));
                    return
                }
                completion(.success(resp.mounts))
            } catch {
                completion(.failure(error))
            }
        } catch {
            completion(.failure(error))
        }
    }

    /// Sends a CONNECT handshake message to the helper, identifying this client's role
    public func connect(role: Api_ConnectRequest.Role, completion: @escaping (Result<Void, Error>) -> Void) {
        var req = Api_ConnectRequest()
        req.role = role
        let typeId = Api_MessageType.connect.rawValue // If you have a new enum value, update this accordingly
        do {
            let requestData = try req.serializedData()
            let lenBuf = withUnsafeBytes(of: UInt32(requestData.count + 1).bigEndian, Array.init)
            var packet = Data()
            packet.append(contentsOf: lenBuf)
            packet.append(UInt8(typeId))
            packet.append(requestData)
            guard socket.send(packet) else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to send CONNECT handshake."])));
                return
            }
            guard let respLenBuf = socket.receive(4), respLenBuf.count == 4 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to read CONNECT handshake response length."])));
                return
            }
            let respLen = Int(UInt32(bigEndian: respLenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
            guard let respTypeData = socket.receive(1), respTypeData.count == 1 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to read CONNECT handshake response type."])));
                return
            }
            let respType = respTypeData[0]
            if respType != typeId {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -5, userInfo: [NSLocalizedDescriptionKey: "Unexpected CONNECT handshake response type: \(respType)"])));
                return
            }
            guard let respBuf = socket.receive(respLen - 1), respBuf.count == respLen - 1 else {
                completion(.failure(NSError(domain: "DiskJockeyHelper", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to read CONNECT handshake response payload."])));
                return
            }
            do {
                var resp = Api_ConnectResponse()
                try resp.merge(serializedData: respBuf)
                if !resp.error.isEmpty {
                    completion(.failure(NSError(domain: "DiskJockeyHelper", code: -7, userInfo: [NSLocalizedDescriptionKey: resp.error])));
                    return
                }
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        } catch {
            completion(.failure(error))
        }
    }
}

