import Foundation
import SwiftProtobuf
import DiskJockeyLibrary

/// MessageProcessor: Sends requests to backend by opening a new connection per request
class MessageProcessor {
    var backendPort: Int? // Set this before making requests

    /// Send a request to the backend, receive response, and handle it
    func sendRequest(type: Api_MessageType, message: SwiftProtobuf.Message) {
        guard let port = backendPort else {
            print("Backend port not set")
            return
        }
        // Open connection
        let socket = TCPSocket()
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { print("Failed to create socket"); return }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { print("Failed to connect to backend"); close(fd); return }
        // Send message
        do {
            let payload = try message.serializedData()
            var data = Data()
            var length = UInt32(payload.count + 1).bigEndian
            data.append(Data(bytes: &length, count: 4))
            data.append(UInt8(type.rawValue))
            data.append(payload)
            _ = data.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress, data.count)
            }
        } catch {
            print("Failed to serialize message: \(error)"); close(fd); return
        }
        // Read response
        guard let (typeId, payload) = receiveMessage(clientFD: fd) else {
            print("Failed to read response from backend"); close(fd); return
        }
        handleMessage(typeId: typeId, payload: payload, clientFD: fd)
        close(fd)
    }

    /// Handles a single message from a backend response
    private func handleMessage(typeId: UInt8, payload: Data, clientFD: Int32) {
        if typeId == Api_MessageType.connect.rawValue {
            // After handshake, send ListPluginsRequest (example: chain request)
            var req = Api_ListPluginsRequest()
            sendRequest(type: .listPluginsRequest, message: req)
        } else if typeId == Api_MessageType.listPluginsRequest.rawValue {
            // Handle ListPluginsResponse
            do {
                let resp = try Api_ListPluginsResponse(serializedBytes: Array(payload))
                print("Active plugins:")
                for plugin in resp.plugins {
                    print(" - \(plugin.name)")
                }
                // Notify UI
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("PluginsListUpdated"), object: nil, userInfo: ["plugins": resp.plugins])
                }
            } catch {
                NSLog("Failed to decode ListPluginsResponse: %@", error.localizedDescription)
            }
        } else {
            // Not sure what to do when you don't understand the message
        }
    }

    /// Reads a framed protobuf message from the socket
    private func receiveMessage(clientFD: Int32) -> (UInt8, Data)? {
        var lenBuf = [UInt8](repeating: 0, count: 4)
        let nLen = read(clientFD, &lenBuf, 4)
        guard nLen == 4 else { return nil }
        
        let msgLen = Int(UInt32(bigEndian: lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
        var typeBuf = [UInt8](repeating: 0, count: 1)
        let nType = read(clientFD, &typeBuf, 1)
        guard nType == 1 else { return nil }
        
        let typeId = typeBuf[0]
        var payloadBuf = [UInt8](repeating: 0, count: msgLen - 1)
        let nPayload = read(clientFD, &payloadBuf, msgLen - 1)
        guard nPayload == msgLen - 1 else { return nil }
        
        let payload = Data(payloadBuf)
        return (typeId, payload)
    }
}

