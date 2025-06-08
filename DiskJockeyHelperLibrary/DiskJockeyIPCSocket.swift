import Foundation

public class DiskJockeyIPCSocket {
    private let socketPath: String
    private var socketFD: Int32 = -1
    private let lock = NSLock()

    public init(socketPath: String) {
        self.socketPath = socketPath
        connect()
    }

    deinit {
        disconnect()
    }

    private func connect() {
        lock.lock(); defer { lock.unlock() }
        if socketFD >= 0 { return }
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPath = socketPath.utf8CString // [CChar], null-terminated
        let sunPathCount = min(sunPath.count, MemoryLayout.size(ofValue: addr.sun_path))
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: sunPathCount) { dst in
                sunPath.withUnsafeBufferPointer { src in
                    memcpy(dst, src.baseAddress, sunPathCount)
                }
            }
        }
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

    // For reconnection logic
    public func ensureConnected() {
        lock.lock(); defer { lock.unlock() }
        if socketFD < 0 { connect() }
    }
}
