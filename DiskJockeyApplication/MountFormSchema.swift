import Foundation
import SwiftUI
import DiskJockeyLibrary

public struct FormField: Identifiable {
    public let id = UUID()
    public let label: String
    public let placeholder: String
    public let isSecure: Bool
    public let key: String
    
    public init(label: String, placeholder: String, key: String, isSecure: Bool) {
        self.label = label
        self.placeholder = placeholder
        self.key = key
        self.isSecure = isSecure
    }
}

/// Defines the schema for mount configuration forms
public struct MountFormSchema {
    /// Returns the form fields for a given mount type
    /// - Parameter mountType: The type of mount to get fields for
    /// - Returns: An array of form fields
    public static func fields(for mountType: String) -> [FormField] {
        let base: [FormField] = [
            .init(label: "Name", placeholder: "Enter name", key: "name", isSecure: false),
            .init(label: "Hostname", placeholder: "host.example.com", key: "hostname", isSecure: false),
            .init(label: "Username", placeholder: "Enter username", key: "username", isSecure: false),
            .init(label: "Password", placeholder: "Enter password", key: "password", isSecure: true),
            .init(label: "Share Name", placeholder: "share", key: "shareName", isSecure: false),
        ]

        return base
    }
    
    /// Creates a new MountPoint from a dictionary of values
    /// - Parameter values: Dictionary of field keys to values
    /// - Returns: A new MountPoint instance
    public static func createMountPoint(from values: [String: Any]) -> MountPoint {
        MountPoint(
            name: values["name"] as? String ?? "",
            type: .webdav, // Default type, can be adjusted based on form
            url: "", // Will be constructed from hostname and share
            username: values["username"] as? String ?? "",
            password: values["password"] as? String ?? "",
            hostname: values["hostname"] as? String,
            shareName: values["shareName"] as? String
        )
    }
    
    /// Updates a MountPoint with values from a dictionary
    /// - Parameters:
    ///   - mountPoint: The MountPoint to update
    ///   - values: Dictionary of field keys to values
    /// - Returns: An updated MountPoint
    public static func update(_ mountPoint: MountPoint, with values: [String: Any]) -> MountPoint {
        var updated = mountPoint
        if let name = values["name"] as? String { updated.name = name }
        if let username = values["username"] as? String { updated.username = username }
        if let password = values["password"] as? String { updated.password = password }
        if let hostname = values["hostname"] as? String { updated.hostname = hostname }
        if let shareName = values["shareName"] as? String { updated.shareName = shareName }
        return updated
    }
}
