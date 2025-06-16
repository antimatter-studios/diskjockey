import Foundation

public class TCPListener: TCPSocket {
    private var acceptThread: Thread?
    private var shouldStopAccepting = false
    public private(set) var actualPort: Int?
    
    public init?(port: Int, onAccept: @escaping (Int32) -> Void) {
        super.init()
        self.actualPort = port
        NSLog("DiskJockey: Attempting to listen on port \(port)")

        lock.lock(); defer { lock.unlock() }
        if socket >= 0 { return nil }

        socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)

        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let localAddr = addr
        let bindResult = withUnsafePointer(to: localAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout.size(ofValue: localAddr)))
            }
        }

        guard bindResult == 0 else {
            close(socket)
            self.socket = -1
            return nil
        }

        // Retrieve the actual port after binding
        var sockAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &sockAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &len)
            }
        }

        if rc == 0 {
            let portValue = Int(UInt16(bigEndian: sockAddr.sin_port))
            self.actualPort = portValue
            NSLog("DiskJockey: Listening port was updated to \(port)")
        } else {
            NSLog("DiskJockey: Could not get port number")
        }

        Darwin.listen(socket, 5)
        shouldStopAccepting = false
        acceptThread = Thread { [weak self] in
            guard let self = self else { return }
            while !self.shouldStopAccepting {
                var clientAddr = sockaddr_in()
                var len = socklen_t(MemoryLayout.size(ofValue: clientAddr))
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.accept(self.socket, $0, &len)
                    }
                }
                if clientFD >= 0 {
                    onAccept(clientFD)
                } else if errno != EINTR {
                    break
                }
            }
        }

        acceptThread?.start()
    }
    
    public func stopAccepting() {
        shouldStopAccepting = true
        if let thread = acceptThread {
            if !thread.isFinished {
                pthread_kill(thread.threadDictionary["NSThreadID"] as! pthread_t, SIGINT)
            }
        }
        acceptThread = nil
    }
}

