import Foundation

@objc protocol DJAgentProtocol: NSObjectProtocol {
    func attachImage(atPath path: String,
                     reply: @escaping (_ slices: [String]?, _ error: String?) -> Void)
    func detachDevice(_ bsdName: String,
                      reply: @escaping (_ success: Bool, _ error: String?) -> Void)
    func mountFSKit(source: String, mountPoint: String, fsType: String,
                    partitionOffset: Int64, partitionLength: Int64,
                    reply: @escaping (_ success: Bool, _ error: String?) -> Void)
    func probeImage(atPath path: String,
                    reply: @escaping (_ json: String?, _ error: String?) -> Void)
}
