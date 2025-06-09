import Foundation

public class TCPSocket {
    internal var socket: Int32 = -1
    internal let lock = NSLock()
    
    public init() {}
    public init(socket: Int32) {
        self.socket = socket
    }
    
    deinit {
        disconnect()
    }
    
    public func send(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard socket >= 0 else { return false }
        let sent = data.withUnsafeBytes { ptr in
            write(socket, ptr.baseAddress, data.count)
        }
        return sent == data.count
    }
    
    public func receive(_ length: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard socket >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let n = read(socket, &buffer, length)
        guard n == length else { return nil }
        return Data(buffer)
    }
    
    public func disconnect() {
        lock.lock(); defer { lock.unlock() }
        if socket >= 0 { close(socket) }
        socket = -1
    }
}