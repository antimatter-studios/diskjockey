//
// NetworkFSDriver.swift — Swift-side wrapper around libnetworkfs.a.
//
// This replaces the earlier per-protocol FTPDriver.swift. libnetworkfs
// is a single c-archive built from vendor/go-networkfs/cmd/networkfs:
// it blank-imports every driver (FTP/SFTP/SMB/Dropbox/WebDAV/…) and
// exposes one C ABI that dispatches by driver_type at mount time.
//
//     networkfs_mount(mount_id, driver_type, config_json)
//     networkfs_stat(mount_id, path, out_json)
//     ...
//
// Why one wrapper instead of five:
//
//   • One Go runtime per process — linking 5 per-driver .a files would
//     stamp out 5 copies of the runtime, the scheduler, and the cgo
//     trampoline. Not cheap for a FileProvider extension that may be
//     respawned constantly.
//   • The wire protocol (FileInfo JSON, path semantics, error text) is
//     identical across every driver — nothing protocol-specific lives
//     here. Protocol-specific fields live on the NetworkFSPersonality
//     config types in DiskJockeyLibrary.
//
// Higher-level per-domain lifecycle lives in FileProviderDirectClient.
//
// JSON shape we decode (`RemoteFileInfo`) matches the Go struct at
// vendor/go-networkfs/pkg/api/driver.go:
//
//     type FileInfo struct {
//         Name    string `json:"name"`
//         Path    string `json:"path"`
//         Size    int64  `json:"size"`
//         IsDir   bool   `json:"is_dir"`
//         ModTime int64  `json:"mod_time"`
//         Mode    uint32 `json:"mode"`
//     }
//
// Error-reporting convention (see vendor/go-networkfs/cmd/networkfs/main.go):
// on failure, `networkfs_stat` / `networkfs_listdir` write the error
// message into `*outJSON` (plain string, not JSON) and return 1. We
// capture that text and surface it in NetworkFSDriverError.
//

import Foundation
import DiskJockeyLibrary

// MARK: - Errors

enum NetworkFSDriverError: Error, CustomStringConvertible {
    /// Config serialization failed before the C call.
    case invalidConfig(String)
    /// `networkfs_mount` return codes, lifted into a Swift enum:
    ///   rc=1 unknown driver type
    ///   rc=2 Go-side mount failed (credentials, network, DNS, TLS…)
    ///   rc=-1 invalid JSON reached the dispatcher
    /// `message` is the classified error text the Go side wrote into its
    /// `outErr` out-param (e.g. `"cannot resolve host"`, `"authentication
    /// failed"`, `"remote path does not exist"`). Empty if the Go side
    /// didn't populate it.
    case mountFailed(code: Int32, driverType: Int32, message: String)
    case unmountFailed(code: Int32)
    /// A path-based op (stat/listdir) returned non-zero. `message` is
    /// the text the Go side wrote into `*outJSON`.
    case operationFailed(op: String, path: String, code: Int32, message: String)
    /// `networkfs_openfile` returned non-zero or gave us a null data pointer.
    case readFailed(path: String, code: Int32)
    /// `networkfs_get_thumbnail` returned non-zero. Distinct case so the
    /// caller can fall back to a generic icon without surfacing the error
    /// the way real read failures do — thumbnails are a "nice to have."
    /// `code` mirrors the C ABI: 1 mount-not-found, 2 driver-not-thumbnailer,
    /// 3 fetch error from the provider.
    case thumbnailFailed(path: String, code: Int32, message: String)
    /// Response bytes were not valid UTF-8 / JSON / decodable.
    case decodeFailed(op: String, underlying: Error)
    /// Write-to-temp-file (fetchFile) failed at the Swift layer, after
    /// the cgo call succeeded. Kept distinct so callers can tell "remote
    /// problem" apart from "disk problem".
    case tempFileFailed(URL, Error)

    var description: String {
        switch self {
        case .invalidConfig(let msg):
            return "NetworkFSDriver: invalid config (\(msg))"
        case .mountFailed(let code, let dt, let message):
            let suffix = message.isEmpty ? "" : ": \(message)"
            return "NetworkFSDriver: networkfs_mount failed (code=\(code) driver_type=\(dt))\(suffix)"
        case .unmountFailed(let code):
            return "NetworkFSDriver: networkfs_unmount failed (code=\(code))"
        case .operationFailed(let op, let path, let code, let message):
            return "NetworkFSDriver: \(op)(\(path)) failed code=\(code) msg=\(message)"
        case .readFailed(let path, let code):
            return "NetworkFSDriver: openfile(\(path)) failed code=\(code)"
        case .thumbnailFailed(let path, let code, let message):
            let suffix = message.isEmpty ? "" : ": \(message)"
            return "NetworkFSDriver: get_thumbnail(\(path)) failed code=\(code)\(suffix)"
        case .decodeFailed(let op, let err):
            return "NetworkFSDriver: \(op) decode failed: \(err)"
        case .tempFileFailed(let url, let err):
            return "NetworkFSDriver: temp file \(url.path) failed: \(err)"
        }
    }
}

// MARK: - Wire type

/// Swift mirror of vendor/go-networkfs/pkg/api/driver.go:FileInfo.
/// Same shape for every backend — that's what makes this wrapper
/// protocol-agnostic.
struct RemoteFileInfo: Codable, Equatable {
    let name: String
    let path: String
    let size: Int64
    let isDir: Bool
    let modTime: Int64
    let mode: UInt32

    enum CodingKeys: String, CodingKey {
        case name, path, size, mode
        case isDir    = "is_dir"
        case modTime  = "mod_time"
    }

    /// Convert to the library-wide DiskJockeyFileItem so the existing
    /// FileProviderItem mapping layer keeps working unchanged.
    func toFileItem() -> DiskJockeyFileItem {
        DiskJockeyFileItem(name: name, size: size, isDirectory: isDir)
    }
}

// MARK: - Driver namespace

/// Stateless wrapper over `libnetworkfs.a`. Every call takes an explicit
/// `mountID` (the same Int32 used at connect time) so the same namespace
/// can serve many domains. The Go side keeps a MountManager keyed by
/// mountID — Swift doesn't need its own table.
///
/// Symbols come from `libnetworkfs.h` via the bridging header. Keeping
/// them as direct references (not `dlsym`) is deliberate — it forces
/// the linker to keep `libnetworkfs.a` contents in the final binary
/// instead of dead-stripping them.
enum NetworkFSDriver {

    // MARK: Version smoke test

    /// Returns the version string baked into libnetworkfs at build time.
    /// Used as a liveness check from FileProviderExtension.init.
    static func libraryVersion() -> String {
        guard let cstr = networkfs_version() else { return "(null)" }
        defer { networkfs_free(cstr) }
        return String(cString: cstr)
    }

    // MARK: Mount / Unmount

    /// Dispatch a `networkfs_mount` call. `driverType` selects the
    /// backend (1=FTP, 2=SFTP, …); `configJSON` is the
    /// protocol-specific map string built by
    /// `StoredMountConfig.mountJSON(password:)`.
    static func connect(mountID: Int32,
                        driverType: Int32,
                        configJSON: String) throws {
        var outErr: UnsafeMutablePointer<CChar>? = nil
        let rc = configJSON.withCString { cjson -> Int32 in
            // networkfs_mount takes *mutable* char* (cgo export sig);
            // the Go side only reads it so the cast is safe.
            let mutableJSON = UnsafeMutablePointer<CChar>(mutating: cjson)
            return networkfs_mount(mountID, driverType, mutableJSON, &outErr)
        }
        let message: String
        if let ptr = outErr {
            message = String(cString: ptr)
            networkfs_free(ptr)
        } else {
            message = ""
        }
        guard rc == 0 else {
            throw NetworkFSDriverError.mountFailed(
                code: rc, driverType: driverType, message: message
            )
        }
    }

    static func disconnect(mountID: Int32) throws {
        let rc = networkfs_unmount(mountID)
        guard rc == 0 else {
            throw NetworkFSDriverError.unmountFailed(code: rc)
        }
    }

    // MARK: Stat / List

    static func stat(mountID: Int32, path: String) throws -> RemoteFileInfo {
        let json = try callJSONOp(op: "stat", path: path) { cpath, outJSON in
            networkfs_stat(mountID, cpath, outJSON)
        }
        do {
            return try JSONDecoder().decode(RemoteFileInfo.self, from: Data(json.utf8))
        } catch {
            throw NetworkFSDriverError.decodeFailed(op: "stat", underlying: error)
        }
    }

    static func listDir(mountID: Int32, path: String) throws -> [RemoteFileInfo] {
        let json = try callJSONOp(op: "listdir", path: path) { cpath, outJSON in
            networkfs_listdir(mountID, cpath, outJSON)
        }
        do {
            return try JSONDecoder().decode([RemoteFileInfo].self, from: Data(json.utf8))
        } catch {
            throw NetworkFSDriverError.decodeFailed(op: "listdir", underlying: error)
        }
    }

    // MARK: File contents

    /// Download the whole file into a caller-provided URL on disk.
    /// The URL's parent directory must exist.
    static func fetchFile(mountID: Int32, path: String, to url: URL) throws {
        var slice = ByteSlice(data: nil, len: 0)
        log.info("fetchFile start mountID=\(mountID) path=\(path) → \(url.path)")
        let rc = withUnsafeMutablePointer(to: &slice) { slicePtr -> Int32 in
            path.withCString { cpath -> Int32 in
                let mutablePath = UnsafeMutablePointer<CChar>(mutating: cpath)
                return networkfs_openfile(mountID, mutablePath, slicePtr)
            }
        }
        log.info("networkfs_openfile returned rc=\(rc) slice.len=\(slice.len) data=\(slice.data == nil ? "nil" : "non-nil")")
        guard rc == 0, slice.data != nil else {
            if let leaked = slice.data { networkfs_free(leaked) }
            throw NetworkFSDriverError.readFailed(path: path, code: rc)
        }
        let dataPtr = slice.data!
        defer { networkfs_free(dataPtr) }

        let count = Int(slice.len)
        let data: Data
        if count == 0 {
            data = Data()
        } else {
            data = dataPtr.withMemoryRebound(to: UInt8.self, capacity: count) { bytes in
                Data(bytes: bytes, count: count)
            }
        }
        log.info("fetchFile writing \(data.count) bytes → \(url.path)")
        do {
            try data.write(to: url, options: .atomic)
            log.info("fetchFile wrote temp file; exists=\(FileManager.default.fileExists(atPath: url.path)) size=\((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1)")
        } catch {
            log.error("fetchFile write failed: \(error)")
            throw NetworkFSDriverError.tempFileFailed(url, error)
        }
    }

    // MARK: Write ops

    /// Upload `data` to `path`, replacing whatever's there. The Go side
    /// copies the bytes via `C.GoBytes` so the Swift pointer only needs
    /// to outlive the call itself.
    static func writeFile(mountID: Int32, path: String, data: Data) throws {
        let count = data.count
        let rc: Int32 = path.withCString { cpath -> Int32 in
            let mutablePath = UnsafeMutablePointer<CChar>(mutating: cpath)
            if count == 0 {
                let slice = ByteSlice(data: nil, len: 0)
                return networkfs_writefile(mountID, mutablePath, slice)
            }
            return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
                // ByteSlice.data is `char*`; rebind the raw bytes so the
                // pointer types line up. Go copies via C.GoBytes, so the
                // pointer only needs to live for this call.
                let basePtr = raw.baseAddress!
                    .bindMemory(to: CChar.self, capacity: count)
                let slice = ByteSlice(
                    data: UnsafeMutablePointer<CChar>(mutating: basePtr),
                    len: count
                )
                return networkfs_writefile(mountID, mutablePath, slice)
            }
        }
        guard rc == 0 else {
            throw NetworkFSDriverError.operationFailed(
                op: "writefile", path: path, code: rc, message: ""
            )
        }
    }

    static func mkdir(mountID: Int32, path: String) throws {
        let rc = path.withCString { cpath -> Int32 in
            let mutablePath = UnsafeMutablePointer<CChar>(mutating: cpath)
            return networkfs_mkdir(mountID, mutablePath)
        }
        guard rc == 0 else {
            throw NetworkFSDriverError.operationFailed(
                op: "mkdir", path: path, code: rc, message: ""
            )
        }
    }

    static func removeItem(mountID: Int32, path: String) throws {
        let rc = path.withCString { cpath -> Int32 in
            let mutablePath = UnsafeMutablePointer<CChar>(mutating: cpath)
            return networkfs_remove(mountID, mutablePath)
        }
        guard rc == 0 else {
            throw NetworkFSDriverError.operationFailed(
                op: "remove", path: path, code: rc, message: ""
            )
        }
    }

    static func renameItem(mountID: Int32, from: String, to: String) throws {
        let rc = from.withCString { cFrom -> Int32 in
            to.withCString { cTo -> Int32 in
                let mutableFrom = UnsafeMutablePointer<CChar>(mutating: cFrom)
                let mutableTo = UnsafeMutablePointer<CChar>(mutating: cTo)
                return networkfs_rename(mountID, mutableFrom, mutableTo)
            }
        }
        guard rc == 0 else {
            throw NetworkFSDriverError.operationFailed(
                op: "rename", path: from, code: rc, message: ""
            )
        }
    }

    // MARK: Thumbnails

    /// Ask the Go driver for a thumbnail (JPEG bytes) for `path`, sized
    /// so the long edge is approximately `sizePx`. Returns the raw image
    /// bytes — caller decodes with `NSImage` / hands to FileProvider.
    ///
    /// Drivers that don't implement Go's `Thumbnailer` interface
    /// (everything except Dropbox today) return rc=2 with message
    /// "driver does not support thumbnails"; we surface that as
    /// `.thumbnailFailed` and the caller falls back to a generic icon.
    static func fetchThumbnail(mountID: Int32, path: String,
                               sizePx: Int32) throws -> Data {
        var slice = ByteSlice(data: nil, len: 0)
        var outErr: UnsafeMutablePointer<CChar>? = nil
        let rc = withUnsafeMutablePointer(to: &slice) { slicePtr -> Int32 in
            path.withCString { cpath -> Int32 in
                let mutablePath = UnsafeMutablePointer<CChar>(mutating: cpath)
                return networkfs_get_thumbnail(
                    mountID, mutablePath, sizePx, slicePtr, &outErr
                )
            }
        }
        let message: String
        if let ptr = outErr {
            message = String(cString: ptr)
            networkfs_free(ptr)
        } else {
            message = ""
        }
        guard rc == 0, let dataPtr = slice.data else {
            if let leaked = slice.data { networkfs_free(leaked) }
            throw NetworkFSDriverError.thumbnailFailed(
                path: path, code: rc, message: message
            )
        }
        defer { networkfs_free(dataPtr) }
        let count = Int(slice.len)
        if count == 0 { return Data() }
        return dataPtr.withMemoryRebound(to: UInt8.self, capacity: count) { bytes in
            Data(bytes: bytes, count: count)
        }
    }

    /// Wire shape of `networkfs_get_stats` JSON. Mirrors the map the
    /// Go side emits in cmd/networkfs/main.go. All zeros means either
    /// "no traffic yet" or "non-HTTP driver" — indistinguishable on
    /// purpose so the poller doesn't have to special-case anything.
    struct TransportStats: Codable, Equatable {
        let bytesRead: UInt64
        let bytesWritten: UInt64
        let opsRead: UInt64
        let opsWritten: UInt64

        static let zero = TransportStats(
            bytesRead: 0, bytesWritten: 0, opsRead: 0, opsWritten: 0
        )

        enum CodingKeys: String, CodingKey {
            case bytesRead    = "bytes_read"
            case bytesWritten = "bytes_written"
            case opsRead      = "ops_read"
            case opsWritten   = "ops_written"
        }
    }

    /// Snapshot of the Go-side per-mount transport counters (see
    /// pkg/api/transport.go). Counts request/response *body* bytes
    /// flowing through the driver's http.Client — covers folder
    /// listings, metadata, OAuth refreshes, and uploads/downloads.
    /// Headers and TCP/TLS framing are not counted.
    ///
    /// Returns `.zero` (instead of throwing) when the rc is non-zero
    /// or the JSON fails to decode — the 1 Hz IOStatsCollector poll
    /// shouldn't generate error spam during transient teardown.
    static func getStats(mountID: Int32) -> TransportStats {
        var outPtr: UnsafeMutablePointer<CChar>? = nil
        let rc = networkfs_get_stats(mountID, &outPtr)
        guard let ptr = outPtr else { return .zero }
        let text = String(cString: ptr)
        networkfs_free(ptr)
        guard rc == 0, let data = text.data(using: .utf8) else { return .zero }
        return (try? JSONDecoder().decode(TransportStats.self, from: data)) ?? .zero
    }

    // MARK: - Internal helpers

    /// Shared body for `networkfs_stat` / `networkfs_listdir`. Handles
    /// marshalling `path` to C, passing `outJSON` by reference, freeing
    /// the returned buffer on success *and* failure, and building the
    /// right NetworkFSDriverError on non-zero rc.
    private static func callJSONOp(
        op: String,
        path: String,
        _ body: (UnsafeMutablePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    ) throws -> String {
        var outPtr: UnsafeMutablePointer<CChar>? = nil
        let rc = path.withCString { cpath -> Int32 in
            let mutablePath = UnsafeMutablePointer<CChar>(mutating: cpath)
            return body(mutablePath, &outPtr)
        }
        // Always free what the Go side allocated (success or failure).
        let responseText: String
        if let ptr = outPtr {
            responseText = String(cString: ptr)
            networkfs_free(ptr)
        } else {
            responseText = ""
        }
        guard rc == 0 else {
            throw NetworkFSDriverError.operationFailed(
                op: op, path: path, code: rc, message: responseText
            )
        }
        return responseText
    }
}
