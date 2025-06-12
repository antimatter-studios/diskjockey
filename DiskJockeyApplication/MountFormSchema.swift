import Foundation
import SwiftUI

struct FormField: Identifiable {
    let id = UUID()
    let label: String
    let placeholder: String
    let isSecure: Bool
    let isOptional: Bool
    let stringKeyPath: WritableKeyPath<MountPoint, String>?
    let optionalKeyPath: WritableKeyPath<MountPoint, String?>?
    
    init(label: String, placeholder: String, keyPath: WritableKeyPath<MountPoint, String>, isSecure: Bool) {
        self.label = label
        self.placeholder = placeholder
        self.isSecure = isSecure
        self.isOptional = false
        self.stringKeyPath = keyPath
        self.optionalKeyPath = nil
    }
    
    init(label: String, placeholder: String, keyPath: WritableKeyPath<MountPoint, String?>, isSecure: Bool) {
        self.label = label
        self.placeholder = placeholder
        self.isSecure = isSecure
        self.isOptional = true
        self.stringKeyPath = nil
        self.optionalKeyPath = keyPath
    }
}

struct MountFormSchema {
    static func fields(for mountType: String) -> [FormField] {
        var base: [FormField] = [
            .init(label: "Name", placeholder: "Enter name", keyPath: \MountPoint.name, isSecure: false),
            .init(label: "Hostname", placeholder: "host.example.com", keyPath: \MountPoint.hostname, isSecure: false),
            .init(label: "Username", placeholder: "Enter username", keyPath: \MountPoint.username, isSecure: false),
            .init(label: "Password", placeholder: "Enter password", keyPath: \MountPoint.password, isSecure: true),
            .init(label: "Share Name", placeholder: "share", keyPath: \MountPoint.shareName, isSecure: false),
        ]

        return base
    }
}
