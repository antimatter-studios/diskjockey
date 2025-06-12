import Foundation

public class DiskJockeyBackendConnection {
    private let host: String
    private let port: Int
    private var socketFD: Int32 = -1
    private let lock = NSLock()

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
        connectSocket()
    }

    private func connectSocket() {
        lock.lock(); defer { lock.unlock() }
        if socketFD >= 0 { return }
        socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &addr.sin_addr)
        let addrSize = socklen_t(MemoryLayout.size(ofValue: addr))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, addrSize)
            }
        }
        if result != 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    public func connect() -> Bool {
        // Send protobuf Connect message as handshake (type 14)
        var connectMsg = Api_ConnectRequest()
        connectMsg.role = .backend
        guard let connectData = try? connectMsg.serializedData() else {
            return false
        }
        let typeId = Api_MessageType.connect.rawValue
        let lenBuf = withUnsafeBytes(of: UInt32(connectData.count + 1).bigEndian) { Data($0) }
        var packet = Data()
        packet.append(lenBuf)
        packet.append(UInt8(typeId))
        packet.append(connectData)
        return send(packet)
    }

    deinit {
        disconnect()
    }

    // private func connect() {
    //     lock.lock(); defer { lock.unlock() }
    //     if socketFD >= 0 { return }
    //     socketFD = socket(AF_INET, SOCK_STREAM, 0)
    //     guard socketFD >= 0 else { return }
    //     var addr = sockaddr_in()
    //     addr.sin_family = sa_family_t(AF_INET)
    //     addr.sin_port = in_port_t(UInt16(port).bigEndian)
    //     inet_pton(AF_INET, host, &addr.sin_addr)
    //     let addrSize = socklen_t(MemoryLayout.size(ofValue: addr))
    //     let result = withUnsafePointer(to: &addr) {
    //         $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
    //             Darwin.connect(socketFD, $0, addrSize)
    //         }
    //     }
    //     if result != 0 {
    //         close(socketFD)
    //         socketFD = -1
    //     }
    // }

    private func disconnect() {
        lock.lock(); defer { lock.unlock() }
        if socketFD >= 0 { close(socketFD) }
        socketFD = -1
    }

    public func send(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard socketFD >= 0 else { return false }
        let sent = data.withUnsafeBytes { ptr in
            write(socketFD, ptr.baseAddress, data.count)
        }
        return sent == data.count
    }

    public func receive(_ length: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard socketFD >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let n = read(socketFD, &buffer, length)
        guard n == length else { return nil }
        return Data(buffer)
    }

    public func ensureConnected() {
        lock.lock(); defer { lock.unlock() }
        if socketFD < 0 { connect() }
    }

    public func listDirectory(mountID: UInt32, path: String = "/") -> [DiskJockeyFileItem]? {
        let typeId = Api_MessageType.listDirRequest.rawValue
        var requestMsg = Api_ListDirRequest()
        requestMsg.mountID = mountID
        requestMsg.path = path
        let requestData: Data
        do {
            requestData = try requestMsg.serializedData()
        } catch {
            DiskJockeyLogger.error("Failed to serialize protobuf request: \(error)")
            return nil
        }
        let lenBuf = withUnsafeBytes(of: UInt32(requestData.count + 1).bigEndian) { Data($0) }
        var packet = Data()
        packet.append(lenBuf)
        packet.append(UInt8(typeId))
        packet.append(requestData)
        guard send(packet) else {
            DiskJockeyLogger.error("Failed to send list directory request over IPC.")
            return nil
        }
        // TODO: Read and decode response
        return nil // placeholder
    }

    public func readFile(mountID: UInt32, path: String) -> Data? {
        let typeId = Api_MessageType.readFileRequest.rawValue
        var requestMsg = Api_ReadFileRequest()
        requestMsg.mountID = mountID
        requestMsg.path = path
        let requestData: Data
        do {
            requestData = try requestMsg.serializedData()
        } catch {
            DiskJockeyLogger.error("Failed to serialize readFile request: \(error)")
            return nil
        }
        let lenBuf = withUnsafeBytes(of: UInt32(requestData.count + 1).bigEndian) { Data($0) }
        var packet = Data()
        packet.append(lenBuf)
        packet.append(UInt8(typeId))
        packet.append(requestData)
        guard send(packet) else {
            DiskJockeyLogger.error("Failed to send readFile request over IPC.")
            return nil
        }
        // TODO: Read and decode response
        return nil // placeholder
    }

    public func writeFile(mountID: UInt32, path: String, data: Data) -> Bool {
        let typeId = Api_MessageType.writeFileRequest.rawValue
        var requestMsg = Api_WriteFileRequest()
        requestMsg.mountID = mountID
        requestMsg.path = path
        requestMsg.data = data
        let requestData: Data
        do {
            requestData = try requestMsg.serializedData()
        } catch {
            DiskJockeyLogger.error("Failed to serialize writeFile request: \(error)")
            return false
        }
        let lenBuf = withUnsafeBytes(of: UInt32(requestData.count + 1).bigEndian) { Data($0) }
        var packet = Data()
        packet.append(lenBuf)
        packet.append(UInt8(typeId))
        packet.append(requestData)
        guard send(packet) else {
            DiskJockeyLogger.error("Failed to send writeFile request over IPC.")
            return false
        }
        // TODO: Read and decode response
        return false // placeholder
    }

    public func stat(mountID: UInt32, path: String) -> Api_FileInfo? {
        let typeId = Api_MessageType.statRequest.rawValue
        var requestMsg = Api_StatRequest()
        requestMsg.mountID = mountID
        requestMsg.path = path
        let requestData: Data
        do {
            requestData = try requestMsg.serializedData()
        } catch {
            DiskJockeyLogger.error("Failed to serialize stat request: \(error)")
            return nil
        }
        let lenBuf = withUnsafeBytes(of: UInt32(requestData.count + 1).bigEndian) { Data($0) }
        var packet = Data()
        packet.append(lenBuf)
        packet.append(UInt8(typeId))
        packet.append(requestData)
        guard send(packet) else {
            DiskJockeyLogger.error("Failed to send stat request over IPC.")
            return nil
        }
        // TODO: Read and decode response
        return nil // placeholder
    }

    public func deleteFile(mountID: UInt32, path: String) -> Bool {
        let typeId = Api_MessageType.deleteFileRequest.rawValue
        var requestMsg = Api_DeleteFileRequest()
        requestMsg.mountID = mountID
        requestMsg.path = path
        let requestData: Data
        do {
            requestData = try requestMsg.serializedData()
        } catch {
            DiskJockeyLogger.error("Failed to serialize deleteFile request: \(error)")
            return false
        }
        let lenBuf = withUnsafeBytes(of: UInt32(requestData.count + 1).bigEndian) { Data($0) }
        var packet = Data()
        packet.append(lenBuf)
        packet.append(UInt8(typeId))
        packet.append(requestData)
        guard send(packet) else {
            DiskJockeyLogger.error("Failed to send deleteFile request over IPC.")
            return false
        }
        // TODO: Read and decode response
        return false // placeholder
    }
}
