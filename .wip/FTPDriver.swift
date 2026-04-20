// FTPDriver.swift - Swift wrapper for go-networkfs libftp.a
//
// This provides a Swift-native interface to the C FTP driver,
// replacing the TCP backend with direct cgo calls.

import Foundation

// MARK: - C Imports
// These functions are exported from libftp.a
@_silgen_name("ftp_version")
func c_ftp_version() -> UnsafeMutablePointer<CChar>?

@_silgen_name("ftp_mount")
func c_ftp_mount(_ mountID: Int32, _ configJSON: UnsafePointer<CChar>?) -> Int32

@_silgen_name("ftp_unmount")
func c_ftp_unmount(_ mountID: Int32) -> Int32

@_silgen_name("ftp_stat")
func c_ftp_stat(_ mountID: Int32, _ path: UnsafePointer<CChar>?, _ outJSON: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

@_silgen_name("ftp_listdir")
func c_ftp_listdir(_ mountID: Int32, _ path: UnsafePointer<CChar>?, _ outJSON: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

@_silgen_name("ftp_openfile")
func c_ftp_openfile(_ mountID: Int32, _ path: UnsafePointer<CChar>?, _ out: UnsafeMutablePointer<ByteSlice>) -> Int32

@_silgen_name("ftp_writefile")
func c_ftp_writefile(_ mountID: Int32, _ path: UnsafePointer<CChar>?, _ data: ByteSlice) -> Int32

@_silgen_name("ftp_mkdir")
func c_ftp_mkdir(_ mountID: Int32, _ path: UnsafePointer<CChar>?) -> Int32

@_silgen_name("ftp_remove")
func c_ftp_remove(_ mountID: Int32, _ path: UnsafePointer<CChar>?) -> Int32

@_silgen_name("ftp_rename")
func c_ftp_rename(_ mountID: Int32, _ oldPath: UnsafePointer<CChar>?, _ newPath: UnsafePointer<CChar>?) -> Int32

@_silgen_name("ftp_free")
func c_ftp_free(_ ptr: UnsafeMutablePointer<CChar>?)

// C struct matching Go's ByteSlice
struct ByteSlice {
    var data: UnsafeMutablePointer<CChar>?
    var len: Int
}

// MARK: - Swift Wrapper

public final class FTPDriver {
    public static let shared = FTPDriver()
    
    private var nextMountID: Int32 = 1000
    private var activeMounts: [Int32: FTPMountConfig] = [:]
    private let queue = DispatchQueue(label: "com.diskjockey.ftp", qos: .utility)
    
    private init() {}
    
    public var version: String {
        guard let cStr = c_ftp_version() else { return "unknown" }
        let str = String(cString: cStr)
        c_ftp_free(cStr)
        return str
    }
    
    // MARK: - Mount / Unmount
    
    public func mount(host: String, port: Int = 21, user: String, pass: String, root: String = "/", ftps: Bool = false) async throws -> Int32 {
        let mountID = queue.sync { () -> Int32 in
            let id = nextMountID
            nextMountID += 1
            activeMounts[id] = FTPMountConfig(host: host, port: port, user: user, pass: pass, root: root)
            return id
        }
        
        let config: [String: String] = [
            "host": host,
            "port": String(port),
            "user": user,
            "pass": pass,
            "root": root,
            "ftps": ftps ? "true" : "false"
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: config)
        guard let jsonStr = String(data: jsonData, encoding: .utf8) else {
            throw FTPError.invalidConfig
        }
        
        return try await queue.asyncThrowing {
            let cConfig = jsonStr.cString(using: .utf8)!
            let result = c_ftp_mount(mountID, cConfig)
            guard result == 0 else {
                throw FTPError.mountFailed(code: Int(result))
            }
            return mountID
        }
    }
    
    public func unmount(_ mountID: Int32) async {
        await queue.async {
            c_ftp_unmount(mountID)
            self.activeMounts.removeValue(forKey: mountID)
        }
    }
    
    // MARK: - File Operations
    
    public func stat(mountID: Int32, path: String) async throws -> FileInfo {
        try await queue.asyncThrowing {
            var outPtr: UnsafeMutablePointer<CChar>?
            let result = path.withCString { cPath in
                c_ftp_stat(mountID, cPath, &outPtr)
            }
            
            guard result == 0, let jsonPtr = outPtr else {
                throw FTPError.operationFailed(code: Int(result), path: path)
            }
            defer { c_ftp_free(jsonPtr) }
            
            let jsonStr = String(cString: jsonPtr)
            let data = jsonStr.data(using: .utf8)!
            return try JSONDecoder().decode(FileInfo.self, from: data)
        }
    }
    
    public func listDir(mountID: Int32, path: String) async throws -> [FileInfo] {
        try await queue.asyncThrowing {
            var outPtr: UnsafeMutablePointer<CChar>?
            let result = path.withCString { cPath in
                c_ftp_listdir(mountID, cPath, &outPtr)
            }
            
            guard result == 0, let jsonPtr = outPtr else {
                throw FTPError.operationFailed(code: Int(result), path: path)
            }
            defer { c_ftp_free(jsonPtr) }
            
            let jsonStr = String(cString: jsonPtr)
            let data = jsonStr.data(using: .utf8)!
            return try JSONDecoder().decode([FileInfo].self, from: data)
        }
    }
    
    public func readFile(mountID: Int32, path: String) async throws -> Data {
        try await queue.asyncThrowing {
            var slice = ByteSlice(data: nil, len: 0)
            let result = path.withCString { cPath in
                c_ftp_openfile(mountID, cPath, &slice)
            }
            
            guard result == 0, let dataPtr = slice.data else {
                throw FTPError.readFailed(path: path)
            }
            defer { c_ftp_free(dataPtr) }
            
            return Data(bytes: dataPtr, count: slice.len)
        }
    }
    
    public func writeFile(mountID: Int32, path: String, data: Data) async throws {
        try await queue.asyncThrowing {
            let bytes = data.withUnsafeBytes { ptr -> [CChar] in
                Array(ptr.bindMemory(to: CChar.self))
            }
            
            var slice = ByteSlice(data: UnsafeMutablePointer<CChar>(mutating: bytes), len: bytes.count)
            
            let result = path.withCString { cPath in
                c_ftp_writefile(mountID, cPath, slice)
            }
            
            guard result == 0 else {
                throw FTPError.writeFailed(path: path)
            }
        }
    }
    
    public func mkdir(mountID: Int32, path: String) async throws {
        try await queue.asyncThrowing {
            let result = path.withCString { cPath in
                c_ftp_mkdir(mountID, cPath)
            }
            guard result == 0 else {
                throw FTPError.mkdirFailed(path: path)
            }
        }
    }
    
    public func remove(mountID: Int32, path: String) async throws {
        try await queue.asyncThrowing {
            let result = path.withCString { cPath in
                c_ftp_remove(mountID, cPath)
            }
            guard result == 0 else {
                throw FTPError.removeFailed(path: path)
            }
        }
    }
    
    public func rename(mountID: Int32, from: String, to: String) async throws {
        try await queue.asyncThrowing {
            let result = from.withCString { cOldPath in
                to.withCString { cNewPath in
                    c_ftp_rename(mountID, cOldPath, cNewPath)
                }
            }
            guard result == 0 else {
                throw FTPError.renameFailed(from: from, to: to)
            }
        }
    }
}

// MARK: - Types

public struct FileInfo: Codable {
    public let name: String
    public let path: String
    public let size: Int64
    public let isDir: Bool
    public let modTime: Int64
    public let mode: UInt32
    
    enum CodingKeys: String, CodingKey {
        case name, path, size
        case isDir = "is_dir"
        case modTime = "mod_time"
        case mode
    }
}

struct FTPMountConfig {
    let host: String
    let port: Int
    let user: String
    let pass: String
    let root: String
}

public enum FTPError: Error {
    case invalidConfig
    case mountFailed(code: Int)
    case operationFailed(code: Int, path: String)
    case readFailed(path: String)
    case writeFailed(path: String)
    case mkdirFailed(path: String)
    case removeFailed(path: String)
    case renameFailed(from: String, to: String)
}

// MARK: - DispatchQueue Extension

extension DispatchQueue {
    func asyncThrowing<T>(execute: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            async {
                do {
                    let result = try execute()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
