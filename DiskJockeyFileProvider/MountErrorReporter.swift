//
// MountErrorReporter.swift — single funnel for `mount.error` /
// `mount.error.cleared` events the host app's DirectMountRegistry
// consumes.
//
// Every code path in this extension that fails an op (connect, stat,
// listDir, fetchFile, init, anything else) calls `emitMountError(...)`
// so the host's red banner above the mount detail view shows what
// went wrong. Per the user's intent: **any** error surfaces, even if
// the only summary we can produce is generic — the raw error always
// goes in `detail` so a power user can read it.
//
// `humaniseMountError` is the small translation table. It only knows
// patterns we've actually observed bite users; everything else gets a
// per-op generic. Add a new branch whenever a recurring error
// warrants a clearer message — over-translating risks hiding the real
// problem.
//

import Foundation

/// Emit a structured `mount.error` event tagged with the per-mount
/// logger's `mount=<domainID>` field. The host app's
/// `DirectMountRegistry.applyExtensionEvent` routes this into its
/// `mountErrors` map keyed by domain, which the detail view's banner
/// reads.
///
/// `op` is a short verb the banner uses to build a headline
/// ("connect", "listDir", "stat", "fetchFile", "init", …). `path` is
/// optional context for ops that operate on a remote path. `error`
/// can be any `Error` — we capture `String(describing:)` verbatim as
/// the banner's "Show raw error" detail.
func emitMountError(mlog: TaggedLogger, op: String,
                    path: String?, error: Error) {
    let raw = "\(error)"
    let summary = humaniseMountError(op: op, raw: raw)
    var fields: [String: String] = [
        "op": op,
        "summary": summary,
        "detail": raw,
    ]
    if let p = path { fields["path"] = p }
    // Keep `message` short — this string lands in the per-mount log
    // strip as a single row, and the giant translated summary would
    // blow out the row's width.
    let shortPath = path.map { " \($0)" } ?? ""
    mlog.event(kind: "mount.error", fields: fields, level: .error,
               message: "mount.error op=\(op)\(shortPath)")
}

/// Emit a `mount.error.cleared` to drop the host-app banner. Called
/// when an op succeeds after a prior failure (today: a fresh
/// connection in `ensureConnected`).
func emitMountErrorCleared(mlog: TaggedLogger) {
    mlog.event(kind: "mount.error.cleared", fields: [:],
               level: .info, message: "mount.error.cleared")
}

/// Translate a raw error string into a one-line headline the user
/// can act on. Falls back to a generic per-op message so the banner
/// is never empty. The raw string is always preserved in the event's
/// `detail` field, so over-translation is the only real risk.
func humaniseMountError(op: String, raw: String) -> String {
    let s = raw.lowercased()

    // ── SSH / SFTP ────────────────────────────────────────────────

    // The Go ssh client's "tried" list reports what *did* run, not
    // what's missing — so `[none publickey]` means ssh-agent
    // answered (or was tried) but no key was accepted, AND no
    // password was sent.
    if s.contains("unable to authenticate") {
        if s.contains("[none publickey]") || s.contains("[publickey]") {
            return "SSH authentication failed: ssh-agent offered no usable key. The agent may be locked (run `ssh-add -L` to check), no key has been added, or the server rejected every key. Disable \"Use SSH Agent\" and use a password, or unlock your agent."
        }
        if s.contains("password") {
            return "SSH authentication failed: server rejected the password. Check your username and password."
        }
        return "SSH authentication failed. Check the credentials and auth method for this mount."
    }
    if s.contains("no authentication method provided") {
        return "No SSH authentication configured. Enter a password or enable \"Use SSH Agent\" in the mount settings."
    }
    if s.contains("ssh: handshake failed") {
        return "SSH handshake failed. The server rejected the connection — check host, port, and credentials."
    }

    // ── FTP ───────────────────────────────────────────────────────

    if s.contains("530 ") || s.contains("login incorrect") || s.contains("login or password incorrect") {
        return "FTP login rejected. Check your username and password."
    }
    if s.contains("502 ") && s.contains("not implemented") {
        return "The FTP server doesn't support a command we need. Try a different remote path or a different server."
    }
    if s.contains("ftp:") && s.contains("dial") {
        return "Could not reach the FTP server. Check host and port."
    }

    // ── SMB ───────────────────────────────────────────────────────

    if s.contains("status_logon_failure") || s.contains("logon failure") {
        return "SMB login rejected. Check your username and password."
    }
    if s.contains("status_access_denied") || s.contains("access denied") {
        return "SMB share denied access. Your account may not have permission for this share."
    }
    if s.contains("status_bad_network_name") || s.contains("bad network name") {
        return "SMB share name not found on the server. Check the share field."
    }

    // ── WebDAV / HTTP ─────────────────────────────────────────────

    if s.contains(" 401 ") || s.contains("unauthorized") {
        return "WebDAV authentication failed. Check your username and password."
    }
    if s.contains(" 403 ") || s.contains("forbidden") {
        return "WebDAV server denied access. Your account may not have permission for this path."
    }
    if s.contains(" 404 ") || s.contains("not found") {
        return "WebDAV path not found. Check the URL and remote path."
    }
    if s.contains(" 500 ") || s.contains("internal server error") {
        return "WebDAV server returned an internal error. Try again, or check the server logs."
    }

    // ── S3 ────────────────────────────────────────────────────────

    if s.contains("invalidaccesskeyid") {
        return "S3 access key ID is not recognised by the server. Check the credentials."
    }
    if s.contains("signaturedoesnotmatch") {
        return "S3 secret access key is wrong. Check the credentials."
    }
    if s.contains("nosuchbucket") {
        return "S3 bucket does not exist on this endpoint. Check the bucket and endpoint."
    }
    if s.contains("accessdenied") {
        return "S3 server denied access. Your credentials don't have permission for this bucket/prefix."
    }

    // ── OAuth (Dropbox / GDrive / OneDrive) ───────────────────────

    if s.contains("invalid_grant") || s.contains("invalid refresh token") {
        return "OAuth refresh token is no longer valid. Re-authenticate in the mount settings."
    }
    if s.contains("invalid_client") {
        return "OAuth client credentials are wrong. Check the client ID and secret."
    }

    // ── Generic network ───────────────────────────────────────────

    if s.contains("connection refused") {
        return "Connection refused. The server isn't accepting connections on that host:port."
    }
    if s.contains("no such host") || s.contains("name resolution") {
        return "Hostname could not be resolved. Check the host field for typos."
    }
    if s.contains("i/o timeout") || s.contains("timeout") {
        return "Connection timed out. The server may be unreachable or behind a firewall."
    }
    if s.contains("network is unreachable") || s.contains("no route to host") {
        return "Network unreachable. Check your internet connection."
    }
    if s.contains("certificate") && (s.contains("expired") || s.contains("invalid") || s.contains("untrusted")) {
        return "TLS certificate problem. The server's certificate is expired, untrusted, or invalid."
    }

    // ── Local config / init failures ──────────────────────────────

    if s.contains("missingpassword") || s.contains("keychain load failed") {
        return "Stored password is missing from the keychain. Re-create the mount or re-enter credentials."
    }
    if s.contains("missingconfig") || s.contains("config load failed") {
        return "Mount configuration is missing on disk. The mount may have been removed or corrupted."
    }

    // ── Per-op generic fallback ───────────────────────────────────

    switch op {
    case "init":     return "The mount could not be prepared. See the raw error for details."
    case "connect":  return "Could not connect to the remote server."
    case "listDir":  return "Listing the remote directory failed."
    case "stat":     return "Querying remote file metadata failed."
    case "fetchFile":return "Downloading the remote file failed."
    default:         return "Remote operation failed."
    }
}
