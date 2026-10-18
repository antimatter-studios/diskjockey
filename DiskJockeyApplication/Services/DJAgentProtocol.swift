import Foundation

@objc protocol DJAgentProtocol: NSObjectProtocol {
    /// Read-only DriverKit media owned by this live XPC connection.
    func attachDriverKitImage(atPath path: String, proof: FileHandle,
                              offset: UInt64, length: UInt64, blockSize: UInt32,
                              reply: @escaping (_ attachmentID: UInt64, _ device: String?, _ error: String?) -> Void)
    /// Identity, never a BSD name; refused for another connection's attachment.
    func detachDriverKitImage(_ attachmentID: UInt64,
                              reply: @escaping (_ success: Bool, _ error: String?) -> Void)
    /// `proof` is the image, opened for reading by the caller: the agent
    /// attaches only a file the caller could read itself (diskjockey#94).
    func attachImage(atPath path: String, proof: FileHandle,
                     reply: @escaping (_ slices: [String]?, _ error: String?) -> Void)
    /// Refused for any device this agent did not attach.
    func detachDevice(_ bsdName: String,
                      reply: @escaping (_ success: Bool, _ error: String?) -> Void)
    func probeImage(atPath path: String,
                    reply: @escaping (_ json: String?, _ error: String?) -> Void)
}
