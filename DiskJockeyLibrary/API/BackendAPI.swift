import Foundation

public class BackendAPI {
    let socket: TCPSocket
    public init(clientFD: Int32) {
        print("[BackendAPI] Created API object for Backend")
        self.socket = TCPSocket(socket: clientFD)
    }
    // Add methods to send/receive messages to the backend as needed
}
