import Cocoa
import Foundation

/// Minimal UNIX domain socket server for DiskJockeyHelper
public class DiskJockeyIPCServer {
    public let socketPath: String
    private var shouldStop = false
    private var serverThread: Thread?
    private var serverSocketFD: Int32 = -1

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func start() throws {
        if serverThread != nil { return }
        shouldStop = false
        serverThread = Thread(target: self, selector: #selector(runServer), object: nil)
        serverThread?.start()
    }

    public func stop() {
        shouldStop = true
        if serverSocketFD >= 0 { close(serverSocketFD) }
        serverSocketFD = -1
        serverThread = nil
    }

    public func sendAck() {
        // Stub: implement actual ACK logic if protocol requires
    }

    @objc private func runServer() {
        unlink(socketPath)
        serverSocketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocketFD >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPath = socketPath.utf8CString
        let sunPathCount = min(sunPath.count, MemoryLayout.size(ofValue: addr.sun_path))
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: sunPathCount) { dst in
                sunPath.withUnsafeBufferPointer { src in
                    memcpy(dst, src.baseAddress, sunPathCount)
                }
            }
        }
        let addrSize = socklen_t(MemoryLayout.size(ofValue: addr))
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverSocketFD, $0, addrSize)
            }
        }
        guard bindResult == 0 else { close(serverSocketFD); return }
        listen(serverSocketFD, 5)
        while !shouldStop {
            var clientAddr = sockaddr()
            var clientLen: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(serverSocketFD, &clientAddr, &clientLen)
            if clientFD < 0 { continue }
            // For demo: read a single byte and treat 99 as shutdown
            var buf = [UInt8](repeating: 0, count: 1)
            let n = read(clientFD, &buf, 1)
            if n == 1 && buf[0] == 99 {
                // Handle shutdown directly
                self.sendAck()
                // TODO: Add any transfer cancellation, persistence, or cleanup here
                self.stop()
                DispatchQueue.main.async {
                    NSApp.terminate(nil as Any?)
                }
            }
            close(clientFD)
        }
        close(serverSocketFD)
        serverSocketFD = -1
    }
}
