import Foundation

public class TCPConnection: TCPSocket {
    public init(host: String = "127.0.0.1", port: Int) {
        super.init()
        lock.lock(); defer { lock.unlock() }
        
        if socket >= 0 { return }
        socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &addr.sin_addr)
        
        let addrSize = socklen_t(MemoryLayout.size(ofValue: addr))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, addrSize)
            }
        }
        
        if result != 0 {
            self.disconnect()
        }
    }
}
