import Foundation

@objc protocol DJAgentProtocol: NSObjectProtocol {
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
