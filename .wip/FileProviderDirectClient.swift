// FileProviderDirectClient.swift - Direct cgo driver client (no XPC/TCP)
//
// This replaces FileProviderXPCClient by using libftp.a directly via FTPDriver.
// No backend process needed - the driver runs in-process via cgo.

import Foundation
import DiskJockeyLibrary

class FileProviderDirectClient {
    static let shared = FileProviderDirectClient()
    
    private var activeMounts: [String: Int32] = [:] // mountID -> driver handle
    private let queue = DispatchQueue(label: "com.diskjockey.direct", qos: .utility)
    
    private init() {}
    
    // MARK: - Mount Management
    
    func connect(mountID: String, config: MountConfig) async throws {
        // Determine driver type from config
        let driverHandle: Int32
        
        switch config.type {
        case .ftp:
            driverHandle = try await FTPDriver.shared.mount(
                host: config.host,
                port: config.port,
                user: config.username,
                pass: config.password,
                root: config.root,
                ftps: config.ftps
            )
        default:
            throw FileProviderError.unsupportedDriver(type: config.type)
        }
        
        activeMounts[mountID] = driverHandle
    }
    
    func disconnect(mountID: String) async {
        guard let handle = activeMounts[mountID] else { return }
        
        await FTPDriver.shared.unmount(handle)
        activeMounts.removeValue(forKey: mountID)
    }
    
    // MARK: - File Operations
    
    func listDirectory(mountID: String, path: String) async throws -> [FileProviderItem] {
        guard let handle = activeMounts[mountID] else {
            throw FileProviderError.notConnected
        }
        
        let entries = try await FTPDriver.shared.listDir(mountID: handle, path: path)
        
        return entries.map { info in
            FileProviderItem(
                identifier: NSFileProviderItemIdentifier(path == "/" ? info.name : "\(path)/\(info.name)"),
                parentIdentifier: NSFileProviderItemIdentifier(path),
                filename: info.name,
                type: info.isDir ? .directory : .regular,
                size: info.size,
                modificationDate: Date(timeIntervalSince1970: TimeInterval(info.modTime))
            )
        }
    }
    
    func fetchContents(mountID: String, path: String) async throws -> Data {
        guard let handle = activeMounts[mountID] else {
            throw FileProviderError.notConnected
        }
        
        return try await FTPDriver.shared.readFile(mountID: handle, path: path)
    }
    
    func writeContents(mountID: String, path: String, data: Data) async throws {
        guard let handle = activeMounts[mountID] else {
            throw FileProviderError.notConnected
        }
        
        try await FTPDriver.shared.writeFile(mountID: handle, path: path, data: data)
    }
    
    func createDirectory(mountID: String, path: String) async throws {
        guard let handle = activeMounts[mountID] else {
            throw FileProviderError.notConnected
        }
        
        try await FTPDriver.shared.mkdir(mountID: handle, path: path)
    }
    
    func deleteItem(mountID: String, path: String) async throws {
        guard let handle = activeMounts[mountID] else {
            throw FileProviderError.notConnected
        }
        
        try await FTPDriver.shared.remove(mountID: handle, path: path)
    }
    
    func renameItem(mountID: String, from: String, to: String) async throws {
        guard let handle = activeMounts[mountID] else {
            throw FileProviderError.notConnected
        }
        
        try await FTPDriver.shared.rename(mountID: handle, from: from, to: to)
    }
    
    func getItemInfo(mountID: String, path: String) async throws -> FileProviderItem {
        guard let handle = activeMounts[mountID] else {
            throw FileProviderError.notConnected
        }
        
        let info = try await FTPDriver.shared.stat(mountID: handle, path: path)
        
        return FileProviderItem(
            identifier: NSFileProviderItemIdentifier(path),
            parentIdentifier: NSFileProviderItemIdentifier((path as NSString).deletingLastPathComponent),
            filename: info.name,
            type: info.isDir ? .directory : .regular,
            size: info.size,
            modificationDate: Date(timeIntervalSince1970: TimeInterval(info.modTime))
        )
    }
}

// MARK: - Types

struct MountConfig {
    enum DriverType {
        case ftp, sftp, smb, dropbox, webdav
    }
    
    let type: DriverType
    let host: String
    let port: Int
    let username: String
    let password: String
    let root: String
    let ftps: Bool
}

enum FileProviderError: Error {
    case unsupportedDriver(type: MountConfig.DriverType)
    case notConnected
    case operationFailed(String)
}
