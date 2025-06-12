import Foundation
import SwiftUI

enum MountType: String, CaseIterable, Identifiable, Codable {
    case webdav = "WebDAV"
    case samba = "Samba"
    var id: String { self.rawValue }
}

struct MountPoint: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var type: MountType
    var url: String
    var username: String
    var password: String
    // Samba-specific
    var hostname: String?
    var shareName: String?
}

class MountModel: ObservableObject {
    @Published var mounts: [MountPoint] = []
    @Published var selectedMount: MountPoint?
    @Published var isAdding: Bool = false
    @Published var newMount: MountPoint = MountPoint(
        id: UUID(),
        name: "",
        type: .webdav,
        url: "",
        username: "",
        password: "",
        hostname: nil,
        shareName: nil
    )
}
