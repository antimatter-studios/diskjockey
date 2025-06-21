import Foundation

//public var MachServiceName: String = "com.antimatterstudios.diskjockey.xpc"

@objc public protocol FileProviderXPCProtocol {
    func handleRequest(_ data: Data, withReply reply: @escaping (Data) -> Void)
}
