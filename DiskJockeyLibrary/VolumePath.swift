//
//  VolumePath.swift — a path inside a mounted volume, held as the bytes
//  the driver uses rather than as a Swift String.
//
//  WHY IT EXISTS (diskjockey#219)
//
//  A Linux filename is a byte string: no NUL, no '/', and no encoding
//  rule. None of the formats these extensions read carries a field that
//  could declare one, so an image built under a non-UTF-8 locale, or
//  copied off a legacy volume, holds names that are not valid UTF-8.
//
//  The volumes turned every name into a String with String(cString:),
//  which REPAIRS invalid UTF-8 — each bad byte becomes U+FFFD. The
//  repair is many-to-one (caf\xE9 and caf\xEA both become caf\u{FFFD}),
//  and the repaired string was then used twice: as the name Finder
//  shows, and, joined onto the parent's path, as the path handed back to
//  the driver, which looked for a file literally called caf\u{FFFD} and
//  found nothing.
//
//  So the path stays bytes from the driver's dirent to the driver's next
//  call, and the name FSKit is given is built from those bytes too
//  (FSFileName(data:)). A String appears only where a person reads it:
//  `description`, for logs.
//
//  A volume adopts this once its driver's C ABI takes paths as bytes.
//  One that still decodes paths as UTF-8 would refuse — or worse,
//  misresolve — the raw bytes this hands it.
//

import FSKit
import Foundation

public struct VolumePath: Hashable, Sendable, CustomStringConvertible {

    private static let separator = UInt8(ascii: "/")

    /// The path's bytes, without a terminating NUL.
    public let bytes: [UInt8]

    /// The volume's root, `/`.
    public static let root = VolumePath(bytes: [separator])

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// A path spelled as text, for the ones the code itself names (`/`).
    public init(_ path: String) {
        self.bytes = Array(path.utf8)
    }

    /// This directory's child `name`, byte for byte. Nil when `name` could
    /// not be one component — empty, or holding a NUL or a `/` — because
    /// no directory can hold such an entry, and passing it on would name
    /// a different file.
    public func appending(_ name: [UInt8]) -> VolumePath? {
        guard !name.isEmpty, !name.contains(0), !name.contains(Self.separator) else {
            return nil
        }
        return VolumePath(bytes: self == .root ? bytes + name : bytes + [Self.separator] + name)
    }

    /// `appending(_:)` for a name FSKit handed in.
    public func appending(_ name: FSFileName) -> VolumePath? {
        appending([UInt8](name.data))
    }

    /// Calls `body` with the path as a NUL-terminated C string, for the
    /// driver's `const char *path` parameters.
    public func withCString<Result>(
        _ body: (UnsafePointer<CChar>) throws -> Result
    ) rethrows -> Result {
        let terminated = bytes.map { CChar(bitPattern: $0) } + [0]
        return try terminated.withUnsafeBufferPointer { try body($0.baseAddress!) }
    }

    /// The path for a person to read: invalid UTF-8 is shown as U+FFFD.
    /// Never hand this back to a driver.
    public var description: String {
        String(decoding: bytes, as: UTF8.self)
    }
}

/// How a driver's C ABI reads a `const char *path` it is handed.
///
/// A volume's paths are bytes from end to end, but a driver can only
/// resolve what its ABI accepts. Each volume declares which ABI it is
/// built against, beside the crate version that decides it.
public enum DriverPathEncoding: Sendable {
    /// The path is taken byte for byte: any name the driver's own
    /// dirents reported resolves.
    case bytes
    /// The path is decoded as UTF-8 first. A path that is not valid
    /// UTF-8 must never reach such a driver: some of them answer an
    /// undecodable path as the ROOT, and report success (rust-fs-erofs
    /// #148, rust-fs-ext4 #418) — so a stat describes the wrong file and
    /// a write or unlink lands on the wrong one.
    case utf8
}

extension VolumePath: ExpressibleByStringLiteral {
    /// A path the code spells as text, such as `"/"`.
    public init(stringLiteral path: String) {
        self.init(path)
    }
}

public extension VolumePath {

    /// Whether the bytes are well-formed UTF-8: no stray continuation or
    /// truncated sequence, no overlong form, no encoded surrogate and
    /// nothing past U+10FFFF — exactly the input Rust's `str::from_utf8`
    /// accepts, which is what a `.utf8` driver runs on it.
    var isValidUTF8: Bool {
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }

    /// The path's last component, as bytes; empty for the root.
    var lastComponent: [UInt8] {
        guard let slash = bytes.lastIndex(of: UInt8(ascii: "/")) else { return bytes }
        return Array(bytes[(slash + 1)...])
    }

    /// This directory's child `name`, as a path a driver whose ABI reads
    /// paths as `encoding` can be handed.
    ///
    /// Throws ENOENT when `name` could not be one component (empty, or
    /// holding a NUL or `/`), since no directory holds such an entry; and
    /// EILSEQ when the driver decodes UTF-8 and the name is not, rather
    /// than hand it a path it would misread.
    func child(_ name: [UInt8], for encoding: DriverPathEncoding) throws -> VolumePath {
        guard let path = appending(name) else { throw POSIXError(.ENOENT) }
        if encoding == .utf8, !path.isValidUTF8 { throw POSIXError(.EILSEQ) }
        return path
    }

    /// `child(_:for:)` for a name FSKit handed in, taken by its bytes:
    /// `FSFileName.string` is nil for a name that is not UTF-8, and FSKit
    /// requires such a name to be looked up all the same.
    func child(_ name: FSFileName, for encoding: DriverPathEncoding) throws -> VolumePath {
        try child([UInt8](name.data), for: encoding)
    }
}

public extension DirentName {
    /// The name FSKit should be given for an entry whose name is `bytes`:
    /// those bytes, whether or not they are valid UTF-8.
    static func fileName(_ bytes: [UInt8]) -> FSFileName {
        FSFileName(data: Data(bytes))
    }
}
