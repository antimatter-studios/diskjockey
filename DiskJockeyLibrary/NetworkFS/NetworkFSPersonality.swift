//
// NetworkFSPersonality.swift — one "personality" per network protocol
// we speak through the combined libnetworkfs.a dispatcher.
//
// The FileProvider extension links a single static archive
// (libnetworkfs.a) that carries *every* driver behind one C ABI:
//
//   networkfs_mount(mount_id, driver_type, config_json)
//   networkfs_stat(mount_id, path, out_json)
//   ...
//
// What differs between FTP, SFTP, SMB, Dropbox, and WebDAV is not the
// call sequence but (a) the numeric driver_type the dispatcher expects
// and (b) the config field set each Go driver's Mount() reads out of
// the decoded map[string]string. Those are the only protocol-specific
// bits, so we capture them in a value type — the "personality" — and
// keep the Swift wrapper around `networkfs_*` (NetworkFSDriver)
// completely protocol-agnostic.
//
// Adding a new protocol is two things:
//   1. Ship a new driver package under go-networkfs/ (Go side)
//   2. Add a new <Proto>MountConfig conforming to NetworkFSPersonality
//      + a case to StoredMountConfig (Swift side)
//
// Memory: the combined lib has one Go runtime + one MountManager, so
// N simultaneous mounts of different protocols cost one runtime, not N.
// That's the whole reason we don't link per-driver .a files from Swift.
//

import Foundation

/// Driver type IDs match the Go-side registry in
/// `vendor/go-networkfs/pkg/api/driver.go`. Raw values are the ints the
/// C dispatcher expects in `networkfs_mount`'s `driver_type` parameter.
/// DO NOT change these — they're part of the C ABI, not cosmetic.
public enum DirectMountScheme: String, Codable, Sendable, CaseIterable {
    case ftp
    case sftp
    case smb
    case dropbox
    case webdav
    case gdrive
    case s3
    case onedrive

    /// The integer the Go dispatcher uses to look up this driver.
    public var driverType: Int32 {
        switch self {
        case .ftp:      return 1
        case .sftp:     return 2
        case .smb:      return 3
        case .dropbox:  return 4
        case .webdav:   return 5
        case .gdrive:   return 6
        case .s3:       return 7
        case .onedrive: return 8
        }
    }

    /// Human-friendly label for UI. Kept here (not in a separate table)
    /// so adding a new scheme is one enum case to update.
    public var displayName: String {
        switch self {
        case .ftp:      return "FTP"
        case .sftp:     return "SFTP"
        case .smb:      return "SMB"
        case .dropbox:  return "Dropbox"
        case .webdav:   return "WebDAV"
        case .gdrive:   return "Google Drive"
        case .s3:       return "S3"
        case .onedrive: return "OneDrive"
        }
    }

    /// Icon for this scheme. Used by sidebar rows and detail headers so
    /// icon selection lives in one place rather than a grab bag of
    /// per-view helpers. Network protocols don't carry an OS identity
    /// (SMB runs on Samba, SFTP runs on Windows, etc.) so we stick with
    /// protocol-level SF Symbols here — the OS-flavored overrides live
    /// where a real OS *is* identifiable, at the fsType layer for
    /// attached disks.
    public var icon: PersonalityIcon {
        switch self {
        case .ftp, .sftp, .smb, .webdav: return .sfSymbol("network")
        case .dropbox:                   return .sfSymbol("shippingbox")
        case .gdrive:                    return .sfSymbol("externaldrive.connected.to.line.below")
        case .onedrive:                  return .sfSymbol("cloud")
        case .s3:                        return .sfSymbol("cube.box")
        }
    }
}

/// How an icon is sourced. SF Symbols for generic concepts,
/// asset-catalog template images for brand-evocative glyphs SF Symbols
/// refuses to ship (Windows tiles, Tux). Callers render via
/// `PersonalityIconView` so the two cases pick up `.foregroundStyle`
/// identically.
public enum PersonalityIcon: Sendable, Equatable {
    case sfSymbol(String)
    case asset(String)
}

/// A personality is the "everything the Go driver needs, plus which
/// driver" packaged as a value type. It owns its own config fields
/// (each protocol has different ones) and knows how to serialize them
/// into the JSON the matching Go driver's `Mount(config map[string]string)`
/// expects.
///
/// Keep the protocol small — adding methods here means adding them to
/// every concrete conforming type. If you need protocol-specific
/// behavior, put it on the concrete struct instead.
public protocol NetworkFSPersonality: Codable, Sendable, Equatable {
    /// Which protocol this personality speaks. Drives the driver_type
    /// parameter of `networkfs_mount` and the routing in
    /// StoredMountConfig's Codable bridge.
    static var scheme: DirectMountScheme { get }

    /// Build the JSON the Go driver's Mount() reads. Password is passed
    /// in separately so the plist on disk never carries it (keychain
    /// owns credentials). Return value is a String because we hand it
    /// straight to `networkfs_mount` via `withCString`.
    func mountJSON(password: String) -> String
}

public extension NetworkFSPersonality {
    /// Convenience for call sites that want a single Int32.
    var driverType: Int32 { Self.scheme.driverType }
}

/// Shared helper: JSON-encode a `[String: String]` dict into the format
/// every Go driver's Mount() expects. Every personality's `mountJSON`
/// ends up calling this.
internal func encodeMountDict(_ dict: [String: String]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
}

/// On-disk / cross-process config envelope. One of these is persisted
/// per NSFileProviderDomain (as a plist in the app-group container) and
/// loaded at extension spawn time. The enum form lets Swift's Codable
/// synthesis handle protocol dispatch for us — decode picks the right
/// case based on the single key present in the plist.
public enum StoredMountConfig: Codable, Sendable, Equatable {
    case ftp(FTPMountConfig)
    case sftp(SFTPMountConfig)
    case smb(SMBMountConfig)
    case dropbox(DropboxMountConfig)
    case webdav(WebDAVMountConfig)
    case gdrive(GDriveMountConfig)
    case s3(S3MountConfig)
    case onedrive(OneDriveMountConfig)

    public var scheme: DirectMountScheme {
        switch self {
        case .ftp:      return .ftp
        case .sftp:     return .sftp
        case .smb:      return .smb
        case .dropbox:  return .dropbox
        case .webdav:   return .webdav
        case .gdrive:   return .gdrive
        case .s3:       return .s3
        case .onedrive: return .onedrive
        }
    }

    public var driverType: Int32 { scheme.driverType }

    public func mountJSON(password: String) -> String {
        switch self {
        case .ftp(let c):      return c.mountJSON(password: password)
        case .sftp(let c):     return c.mountJSON(password: password)
        case .smb(let c):      return c.mountJSON(password: password)
        case .dropbox(let c):  return c.mountJSON(password: password)
        case .webdav(let c):   return c.mountJSON(password: password)
        case .gdrive(let c):   return c.mountJSON(password: password)
        case .s3(let c):       return c.mountJSON(password: password)
        case .onedrive(let c): return c.mountJSON(password: password)
        }
    }

    /// One-line summary suitable for logs and compact UI rows. Each
    /// protocol decides what its "where" means (host:port, url,
    /// account…) — there's no uniform "endpoint" shape across all
    /// protocols.
    public var displayLocation: String {
        switch self {
        case .ftp(let c):     return "\(c.host):\(c.port)"
        case .sftp(let c):    return "\(c.host):\(c.port)"
        case .smb(let c):     return "\(c.host)/\(c.share)"
        case .dropbox:        return "dropbox.com"
        case .webdav(let c):  return c.url
        case .gdrive:         return "drive.google.com"
        case .s3(let c):      return "\(c.endpoint)/\(c.bucket)"
        case .onedrive:       return "onedrive.live.com"
        }
    }
}
