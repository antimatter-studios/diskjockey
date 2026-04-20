public enum DiskTypeEnum: String, Codable {
    case localdirectory = "localdirectory"
    case dropbox = "dropbox"
    case webdav = "webdav"
    case sftp = "sftp"
    case ftp = "ftp"
    /// FTP handled entirely by the host app + FileProvider extension via
    /// the direct-linked Go driver (libftp.a). Bypasses the backend TCP
    /// server, so this works without a running backend.
    case ftpDirect = "ftp_direct"
    case samba = "samba"

    public var displayName: String {
        switch self {
        case .localdirectory: return "Local Directory"
        case .dropbox: return "Dropbox"
        case .webdav: return "WebDAV"
        case .sftp: return "SFTP"
        case .ftp: return "FTP"
        case .ftpDirect: return "FTP (Direct)"
        case .samba: return "Samba"
        }
    }

    public var systemImage: String {
        switch self {
        case .localdirectory: return "folder"
        case .dropbox: return "network"
        case .webdav: return "globe"
        case .sftp: return "network"
        case .ftp: return "network"
        case .ftpDirect: return "bolt.horizontal.circle"
        case .samba: return "network"
        }
    }

    /// True for disk types that DiskJockey mounts without routing through
    /// the backend TCP server. The UI should skip backend-connectivity
    /// preconditions for these.
    public var isDirect: Bool {
        switch self {
        case .ftpDirect: return true
        default: return false
        }
    }
}
