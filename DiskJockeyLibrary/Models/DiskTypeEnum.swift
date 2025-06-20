public enum DiskTypeEnum: String, Codable {
    case localdirectory = "localdirectory"
    case dropbox = "dropbox"
    case webdav = "webdav"
    case sftp = "sftp"
    case ftp = "ftp"
    case samba = "samba"
    
    public var displayName: String {
        switch self {
        case .localdirectory: return "Local Directory"
        case .dropbox: return "Dropbox"
        case .webdav: return "WebDAV"
        case .sftp: return "SFTP"
        case .ftp: return "FTP"
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
        case .samba: return "network"
        }
    }
}
