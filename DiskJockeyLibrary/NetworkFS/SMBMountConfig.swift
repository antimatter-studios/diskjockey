//
// SMBMountConfig.swift — personality for the SMB driver (SMB2+ only;
// the Go library is go-smb2 which doesn't speak SMB1 and we wouldn't
// want it to).
//
// Fields match `smb.Mount(config map[string]string)` in
// vendor/go-networkfs/smb/smb.go. `share` is the share name mounted
// against the host (e.g. "public", "homes"); `rootPath` is an optional
// subpath inside that share.
//

import Foundation

public struct SMBMountConfig: NetworkFSPersonality {
    public static let scheme: DirectMountScheme = .smb

    public let host: String
    public let port: Int
    public let share: String
    public let user: String
    /// Subdirectory inside the share, or empty / "/" for the share root.
    public let rootPath: String

    public init(host: String, port: Int = 445, share: String,
                user: String, rootPath: String = "/") {
        self.host = host
        self.port = port
        self.share = share
        self.user = user
        self.rootPath = rootPath
    }

    public func mountJSON(password: String) -> String {
        encodeMountDict([
            "host":  host,
            "port":  String(port),
            "share": share,
            "user":  user,
            "pass":  password,
            "root":  rootPath,
        ])
    }
}
