//
// SFTPMountConfig.swift — personality for the SFTP driver.
//
// Fields match `sftp.Mount(config map[string]string)` in
// vendor/go-networkfs/sftp/sftp.go. Default port is 22.
//
// `useSSHAgent` flips the Go driver to authenticate via `SSH_AUTH_SOCK`
// instead of password. When true, the password passed to mountJSON is
// ignored by the Go side (we still pass it for symmetry).
//

import Foundation

public struct SFTPMountConfig: NetworkFSPersonality {
    public static let scheme: DirectMountScheme = .sftp

    public let host: String
    public let port: Int
    public let user: String
    public let rootPath: String
    /// If true, the Go driver tries ssh-agent first and falls back to
    /// password. If false, password-only.
    public let useSSHAgent: Bool

    public init(host: String, port: Int = 22, user: String,
                rootPath: String = "/", useSSHAgent: Bool = false) {
        self.host = host
        self.port = port
        self.user = user
        self.rootPath = rootPath
        self.useSSHAgent = useSSHAgent
    }

    public func mountJSON(password: String) -> String {
        encodeMountDict([
            "host":          host,
            "port":          String(port),
            "user":          user,
            "pass":          password,
            "root":          rootPath,
            "use_ssh_agent": useSSHAgent ? "true" : "false",
        ])
    }
}
