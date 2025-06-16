import Foundation

public class ApplicationAPI {
    let socket: TCPSocket
    public init(clientFD: Int32) {
        print("DiskJockey: [ApplicationAPI] Created API object for Application")
        self.socket = TCPSocket(socket: clientFD)
    }
    // Add methods to send/receive messages to the application as needed
}
