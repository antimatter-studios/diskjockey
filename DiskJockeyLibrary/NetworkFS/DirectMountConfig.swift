//
// DirectMountConfig.swift — data model shared between the host app
// (writes it when the user creates a direct mount) and the FileProvider
// extension (reads it at operation time to know where to connect).
//
// The host persists one `DirectMountConfig` plist per domain under
// `<app-group>/MountConfigs/<domain-id>.plist`; the extension reads
// the matching plist + pulls the password from the shared keychain.
//
// Kept in DiskJockeyLibrary so both targets see the same type without
// duplicating the shape in two places.
//

import Foundation

/// Protocol scheme the direct driver should speak. The `rawValue` maps
/// 1:1 to the cgo export prefix — `.ftp` → `ftp_mount` / `ftp_listdir`
/// / etc. Adding a new scheme means shipping a new driver library and
/// adding a case here.
public enum DirectMountScheme: String, Codable, Sendable {
    case ftp
    // Future: case sftp, smb, webdav, …
}

/// Everything the extension needs to connect to a remote mount, minus
/// the password (which lives in the keychain). Purely a value type;
/// Codable → plist is the persistence format (LittleEndian plist in
/// the app-group container, one file per domain).
public struct DirectMountConfig: Codable, Sendable, Equatable {
    public let scheme: DirectMountScheme
    public let host: String
    public let port: Int
    public let user: String
    /// Remote root path (server-side), e.g. "/" or "/public". Not the
    /// local mount point — FileProvider chooses that.
    public let rootPath: String
    /// True = FTPS (explicit AUTH TLS). False = plain FTP.
    public let ftps: Bool

    public init(scheme: DirectMountScheme, host: String, port: Int,
                user: String, rootPath: String = "/", ftps: Bool = false) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.user = user
        self.rootPath = rootPath
        self.ftps = ftps
    }

    /// Build the JSON config the libftp.a `ftp_mount` export expects.
    /// The C side unmarshals this into a `map[string]string`, so every
    /// value is stringified (no structural nesting). Password is
    /// injected at call time from the keychain; callers shouldn't
    /// persist this JSON anywhere.
    public func mountJSON(password: String) -> String {
        let dict: [String: String] = [
            "host":  host,
            "port":  String(port),
            "user":  user,
            "pass":  password,
            "root":  rootPath,
            "ftps":  ftps ? "true" : "false",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
