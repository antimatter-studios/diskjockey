import Foundation

public class DiskJockeyIPCConnectionPool {
    private let socketPath: String
    private let maxConnections: Int
    private var pool: [DiskJockeyIPCSocket] = []
    private let poolLock = NSLock()

    public init(socketPath: String, maxConnections: Int = 4) {
        self.socketPath = socketPath
        self.maxConnections = maxConnections
    }

    public func acquire() -> DiskJockeyIPCSocket {
        poolLock.lock(); defer { poolLock.unlock() }
        if let socket = pool.popLast() {
            socket.ensureConnected()
            return socket
        }
        return DiskJockeyIPCSocket(socketPath: socketPath)
    }

    public func release(_ socket: DiskJockeyIPCSocket) {
        poolLock.lock(); defer { poolLock.unlock() }
        if pool.count < maxConnections {
            pool.append(socket)
        } else {
            // Drop socket if pool is full
        }
    }
}
