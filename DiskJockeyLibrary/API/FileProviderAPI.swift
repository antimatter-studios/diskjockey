import Foundation

public class FileProviderAPI {
    let socket: TCPSocket
    public init(clientFD: Int32) {
        print("DiskJockey: [FileProviderAPI] Created API object for FileProvider")
        self.socket = TCPSocket(socket: clientFD)
    }
    // Add methods to send/receive messages to the file provider as needed
}
