//
// WebDAVMountConfig.swift — personality for the WebDAV driver.
//
// The Go driver (vendor/go-networkfs/webdav/webdav.go) accepts either
// a complete `url` (preferred — handles http-vs-https and non-standard
// ports cleanly) or host+port+path. We standardize on the URL form in
// Swift because that's what users actually paste in — "https://box.com/dav/"
// is one field instead of four.
//
// `pathPrefix` is redundant when `url` already includes the path but we
// expose it as a separate field anyway: a number of WebDAV servers
// (Nextcloud, SabreDAV) host multiple mount points under one origin
// and it's nicer UX to let the user type the base URL once and switch
// prefixes. If you pass a prefix, the Go driver appends it to the URL.
//

import Foundation

public struct WebDAVMountConfig: NetworkFSPersonality {
    public static let scheme: DirectMountScheme = .webdav

    /// Base URL of the WebDAV endpoint, e.g. `https://dav.example.com/`
    /// or `https://nextcloud.example.com/remote.php/dav/files/alice/`.
    /// Must be absolute; empty string is rejected by the Go driver.
    public let url: String
    public let user: String
    /// Optional subpath appended to `url`. Most users leave this "/".
    public let pathPrefix: String

    public init(url: String, user: String, pathPrefix: String = "/") {
        self.url = url
        self.user = user
        self.pathPrefix = pathPrefix
    }

    public func mountJSON(password: String) -> String {
        encodeMountDict([
            "url":  url,
            "user": user,
            "pass": password,
            "path": pathPrefix,
        ])
    }
}
