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

public extension DirentName {
    /// The name FSKit should be given for an entry whose name is `bytes`:
    /// those bytes, whether or not they are valid UTF-8.
    static func fileName(_ bytes: [UInt8]) -> FSFileName {
        FSFileName(data: Data(bytes))
    }
}
