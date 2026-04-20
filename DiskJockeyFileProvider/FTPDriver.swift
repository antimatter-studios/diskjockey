//
// FTPDriver.swift — Swift-side wrapper around libftp.a (cgo c-archive).
//
// Every FTP operation we expose is a thin translation: marshal Swift
// types into C strings, call the `ftp_*` function from libftp, parse
// any returned JSON back into Swift, and release the C-allocated
// memory with `ftp_free`.
//
// The libftp.a side owns a single global `FTPDriver{}` keyed by mountID
// (int). This Swift namespace is stateless; callers pass `mountID`
// explicitly. Higher-level per-domain lifecycle lives in
// FileProviderDirectClient.swift.
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
// Error-reporting convention (see vendor/go-networkfs/ftp/cmd/ftp/main.go):
// on failure, `ftp_stat` / `ftp_listdir` write the error message into
// `*outJSON` (plain string, not JSON) and return 1. We capture that
// text and surface it in FTPDriverError.
//

import Foundation
import DiskJockeyLibrary

// MARK: - Errors

enum FTPDriverError: Error, CustomStringConvertible {
    /// Config serialization / JSON marshaling before the C call failed.
    case invalidConfig(String)
    /// `ftp_mount` returned non-zero. No error text is available; the
    /// Go side swallows the underlying error and just returns a code.
    case mountFailed(code: Int32)
    /// `ftp_unmount` returned non-zero.
    case unmountFailed(code: Int32)
    /// A path-based op (stat/listdir) returned non-zero. `message` is
    /// the text the Go side wrote into `*outJSON`.
    case operationFailed(op: String, path: String, code: Int32, message: String)
    /// `ftp_openfile` returned non-zero or gave us a null data pointer.
    case readFailed(path: String, code: Int32)
    /// Response bytes were not valid UTF-8 / JSON / decodable.
    case decodeFailed(op: String, underlying: Error)
    /// Write-to-temp-file (fetchFile) failed at the Swift layer, after
    /// the cgo call succeeded. Kept distinct so callers can tell "remote
    /// problem" apart from "disk problem".
    case tempFileFailed(URL, Error)

    var description: String {
        switch self {
        case .invalidConfig(let msg):
            return "FTPDriver: invalid config (\(msg))"
        case .mountFailed(let code):
            return "FTPDriver: ftp_mount failed (code=\(code))"
        case .unmountFailed(let code):
            return "FTPDriver: ftp_unmount failed (code=\(code))"
        case .operationFailed(let op, let path, let code, let message):
            return "FTPDriver: \(op)(\(path)) failed code=\(code) msg=\(message)"
        case .readFailed(let path, let code):
            return "FTPDriver: openfile(\(path)) failed code=\(code)"
        case .decodeFailed(let op, let err):
            return "FTPDriver: \(op) decode failed: \(err)"
        case .tempFileFailed(let url, let err):
            return "FTPDriver: temp file \(url.path) failed: \(err)"
        }
    }
}

// MARK: - Wire type

/// Swift mirror of vendor/go-networkfs/pkg/api/driver.go:FileInfo.
/// Internal so FileProviderDirectClient / the Extension can hand these
/// around without re-decoding.
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

/// Stateless wrapper over `libftp.a`. All calls take an explicit
/// `mountID` so the same namespace can serve many domains.
///
/// Symbols come from `libftp.h` via the bridging header. Keeping them
/// as direct references (not `dlsym`) is deliberate — it forces the
/// linker to keep `libftp.a` contents in the final binary instead of
/// dead-stripping them.
enum FTPDriver {

    // MARK: Version smoke test

    /// Returns the version string baked into libftp at build time.
    /// Used as a liveness check from FileProviderExtension.init.
    static func libraryVersion() -> String {
        guard let cstr = ftp_version() else { return "(null)" }
        defer { ftp_free(cstr) }
        return String(cString: cstr)
    }

    // MARK: Mount / Unmount

    static func connect(mountID: Int32,
                        config: DirectMountConfig,
                        password: String) throws {
        let json = config.mountJSON(password: password)
        let rc = json.withCString { cjson -> Int32 in
            // ftp_mount takes *mutable* char* (cgo export signature);
            // the Go side only reads it so the cast is safe.
            let mutableJSON = UnsafeMutablePointer<CChar>(mutating: cjson)
            return ftp_mount(mountID, mutableJSON)
        }
        guard rc == 0 else {
            throw FTPDriverError.mountFailed(code: rc)
        }
    }

    static func disconnect(mountID: Int32) throws {
        let rc = ftp_unmount(mountID)
        guard rc == 0 else {
            throw FTPDriverError.unmountFailed(code: rc)
        }
    }

    // MARK: Stat / List

    static func stat(mountID: Int32, path: String) throws -> RemoteFileInfo {
        let json = try callJSONOp(op: "stat", path: path) { cpath, outJSON in
            ftp_stat(mountID, cpath, outJSON)
        }
        do {
            return try JSONDecoder().decode(RemoteFileInfo.self, from: Data(json.utf8))
        } catch {
            throw FTPDriverError.decodeFailed(op: "stat", underlying: error)
        }
    }

    static func listDir(mountID: Int32, path: String) throws -> [RemoteFileInfo] {
        let json = try callJSONOp(op: "listdir", path: path) { cpath, outJSON in
            ftp_listdir(mountID, cpath, outJSON)
        }
        do {
            return try JSONDecoder().decode([RemoteFileInfo].self, from: Data(json.utf8))
        } catch {
            throw FTPDriverError.decodeFailed(op: "listdir", underlying: error)
        }
    }

    // MARK: File contents

    /// Download the whole file into a caller-provided URL on disk.
    /// The URL's parent directory must exist.
    static func fetchFile(mountID: Int32, path: String, to url: URL) throws {
        var slice = ByteSlice(data: nil, len: 0)
        let rc = withUnsafeMutablePointer(to: &slice) { slicePtr -> Int32 in
            path.withCString { cpath -> Int32 in
                let mutablePath = UnsafeMutablePointer<CChar>(mutating: cpath)
                return ftp_openfile(mountID, mutablePath, slicePtr)
            }
        }
        guard rc == 0, let dataPtr = slice.data, slice.len >= 0 else {
            // Defensive: if the Go side returned non-zero but still
            // allocated a buffer, free it.
            if let leaked = slice.data { ftp_free(leaked) }
            throw FTPDriverError.readFailed(path: path, code: rc)
        }
        defer { ftp_free(dataPtr) }

        // Copy the bytes out before the defer'd free. We can't hand
        // the cgo pointer upward — ftp_free will pull the rug.
        let count = Int(slice.len)
        let data = dataPtr.withMemoryRebound(to: UInt8.self, capacity: count) { bytes in
            Data(bytes: bytes, count: count)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw FTPDriverError.tempFileFailed(url, error)
        }
    }

    // MARK: - Internal helpers

    /// Shared body for `ftp_stat` / `ftp_listdir`. Handles marshalling
    /// `path` to C, passing `outJSON` by reference, freeing the
    /// returned buffer on success *and* failure, and building the
    /// right `FTPDriverError` on non-zero rc.
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
            ftp_free(ptr)
        } else {
            responseText = ""
        }
        guard rc == 0 else {
            throw FTPDriverError.operationFailed(
                op: op, path: path, code: rc, message: responseText
            )
        }
        return responseText
    }
}
