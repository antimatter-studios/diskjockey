//
//  DiskJockeyHelper.swift
//  DiskJockeyHelper
//
//  Created by Chris Thomas on 07.06.25.
//

import Foundation

/// DiskJockeyHelper: Main helper API for mount management and event routing
public class DiskJockeyAPI {
    private let pool: DiskJockeyIPCConnectionPool
    
    public init(socketPath: String) {
        self.pool = DiskJockeyIPCConnectionPool(socketPath: socketPath)
    }
    
    /// Mount a new remote volume
    public func mount(name: String, pluginType: String, config: [String: String], completion: @escaping (Result<Api_MountInfo, Error>) -> Void) {
        let socket = pool.acquire()
        defer { pool.release(socket) }
        var req = Api_MountRequest()
        req.name = name
        req.pluginType = pluginType
        req.config = config
        let typeId: UInt8 = 20 // Example type ID for MountRequest; ensure this matches backend
        do {
            let requestData = try req.serializedData()
            var lenBuf = withUnsafeBytes(of: UInt32(requestData.count + 1).bigEndian, Array.init)
            var packet = Data()
            packet.append(contentsOf: lenBuf)
            packet.append(typeId)
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
                    completion(Result.failure(NSError(domain: "DiskJockeyHelper", code: -7, userInfo: [NSLocalizedDescriptionKey: resp.error])));
                    return
                }
                completion(Result.success(resp.mount))
            } catch {
                completion(Result.failure(error))
            }
        } catch {
            completion(.failure(error))
        }
    }
    
    /// Unmount a volume
    public func unmount(name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let socket = pool.acquire()
        defer { pool.release(socket) }
        var req = Api_UnmountRequest()
        req.name = name
        let typeId: UInt8 = 21 // Example type ID for UnmountRequest; ensure this matches backend
        do {
            let requestData = try req.serializedData()
            var lenBuf = withUnsafeBytes(of: UInt32(requestData.count + 1).bigEndian, Array.init)
            var packet = Data()
            packet.append(contentsOf: lenBuf)
            packet.append(typeId)
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
    
    /// List current mounts
    public func listMounts(completion: @escaping (Result<[Api_MountInfo], Error>) -> Void) {
        let socket = pool.acquire()
        defer { pool.release(socket) }
        let req = Api_ListMountsRequest()
        let typeId: UInt8 = 22 // Example type ID for ListMountsRequest; ensure this matches backend
        do {
            let requestData = try req.serializedData()
            var lenBuf = withUnsafeBytes(of: UInt32(requestData.count + 1).bigEndian, Array.init)
            var packet = Data()
            packet.append(contentsOf: lenBuf)
            packet.append(typeId)
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
                    completion(Result.failure(NSError(domain: "DiskJockeyHelper", code: -7, userInfo: [NSLocalizedDescriptionKey: resp.error])));
                    return
                }
                completion(Result.success(resp.mounts))
            } catch {
                completion(Result.failure(error))
            }
        } catch {
            completion(.failure(error))
        }
    }
    
    /// Listen for mount status updates from the backend (event-driven)
    public func onMountStatusUpdate(_ handler: @escaping (Api_MountStatusUpdate) -> Void) {
        // TODO: Implement event subscription/dispatch
    }
}
