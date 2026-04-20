//
// FTPMountConfig.swift — personality for the FTP driver.
//
// Fields are the ones `ftp.Mount(config map[string]string)` actually
// reads in vendor/go-networkfs/ftp/ftp.go. Password is passed in at
// call time from the keychain; never persisted here.
//

import Foundation

public struct FTPMountConfig: NetworkFSPersonality {
    public static let scheme: DirectMountScheme = .ftp

    public let host: String
    public let port: Int
    public let user: String
    /// Remote root path the driver chroots into (server-side).
    public let rootPath: String
    /// True = FTPS (explicit AUTH TLS). False = plain FTP.
    public let ftps: Bool

    public init(host: String, port: Int = 21, user: String,
                rootPath: String = "/", ftps: Bool = false) {
        self.host = host
        self.port = port
        self.user = user
        self.rootPath = rootPath
        self.ftps = ftps
    }

    public func mountJSON(password: String) -> String {
        encodeMountDict([
            "host": host,
            "port": String(port),
            "user": user,
            "pass": password,
            "root": rootPath,
            "ftps": ftps ? "true" : "false",
        ])
    }
}
