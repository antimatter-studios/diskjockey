import Foundation

/// The C transport opens only the descriptor this check proves the caller
/// could read. The image reader duplicates that descriptor, never its path.
@_cdecl("DJAgentAuthorizeImage")
func DJAgentAuthorizeImage(_ path: UnsafePointer<CChar>?, _ proof: Int32) -> Bool {
    guard let path else { return false }
    if case .success = AgentAuthority.attachableImage(String(cString: path), proof: proof) {
        return true
    }
    return false
}
