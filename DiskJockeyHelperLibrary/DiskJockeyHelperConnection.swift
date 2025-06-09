import Foundation

public class DiskJockeyHelperConnection {
    public let port: Int
    public let serverFD: Int32
    private let lock = NSLock()
    public var isListening: Bool = false
    private var acceptThread: Thread?
    private var shouldStop = false

    public init?() {
        // Open TCP server socket on loopback, random port
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // random port
        var addrCopy = addr
        inet_pton(AF_INET, "127.0.0.1", &addrCopy.sin_addr)
        let bindResult = withUnsafePointer(to: &addrCopy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout.size(ofValue: addr)))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            return nil
        }
        addrCopy = addr
        var len = socklen_t(MemoryLayout.size(ofValue: addrCopy))
        getsockname(fd, withUnsafeMutablePointer(to: &addrCopy) {
            UnsafeMutableRawPointer($0).assumingMemoryBound(to: sockaddr.self)
        }, &len)
        let actualPort = Int(UInt16(bigEndian: addrCopy.sin_port))
        listen(fd, 5)
        self.port = actualPort
        self.serverFD = fd
        self.isListening = true
    }

    deinit {
        if isListening {
            close(serverFD)
        }
    }

    public func acceptConnection() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        guard isListening else { return nil }
        var addr = sockaddr()
        var len: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
        let clientFD = Darwin.accept(serverFD, &addr, &len)
        return clientFD >= 0 ? clientFD : nil
    }


    public func startAccepting(handler: @escaping (_ typeId: UInt8, _ payload: Data, _ clientFD: Int32) -> Void) {
        guard acceptThread == nil else { return }
        shouldStop = false
        acceptThread = Thread {
            while !self.shouldStop {
                var addr = sockaddr()
                var len: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
                let clientFD = Darwin.accept(self.serverFD, &addr, &len)
                if clientFD < 0 { continue }
                // Read length prefix (4 bytes)
                var lenBuf = [UInt8](repeating: 0, count: 4)
                let nLen = read(clientFD, &lenBuf, 4)
                if nLen != 4 {
                    close(clientFD)
                    continue
                }
                let msgLen = Int(UInt32(bigEndian: lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
                // Read typeId (1 byte)
                var typeIdBuf = [UInt8](repeating: 0, count: 1)
                let nType = read(clientFD, &typeIdBuf, 1)
                if nType != 1 {
                    close(clientFD)
                    continue
                }
                let typeId = typeIdBuf[0]
                // Read protobuf payload
                var payloadBuf = [UInt8](repeating: 0, count: msgLen - 1)
                let nPayload = read(clientFD, &payloadBuf, msgLen - 1)
                if nPayload != msgLen - 1 {
                    close(clientFD)
                    continue
                }
                handler(typeId, Data(payloadBuf), clientFD)
            }
        }
        acceptThread?.start()
    }

    public func stopAccepting() {
        shouldStop = true
        acceptThread = nil
    }
}
