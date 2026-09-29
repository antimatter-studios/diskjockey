//
//  DirentName.swift — the bytes of a directory entry's name, taken from a
//  driver's fixed-size `char name[N]` field without reading past it.
//
//  WHY IT EXISTS (diskjockey#207)
//
//  The volumes read a dirent's name by rebinding the imported array to a
//  hand-written `capacity:` and scanning for the NUL with
//  `String(cString:)`. The capacity drifted from the header: SquashFS's
//  array is 257 bytes, because a SquashFS name can be 256 bytes and needs
//  a NUL after it, and the Swift side said 256. For a maximum-length name
//  the terminator sat one past the region the closure had been promised.
//
//  Both halves of that are avoidable. The array's size is known to the
//  compiler — `withUnsafeBytes(of:)` over the imported tuple spans exactly
//  its declared bytes, so there is no number to copy by hand — and where
//  the ABI reports the name's length (`name_len`), the name is taken by
//  count rather than found by scanning, so it does not depend on the
//  terminator at all.
//

import Foundation

public enum DirentName {

    /// The name held in `field`, a C `char name[N]` array as Swift imports
    /// it (a tuple of `N` `CChar`s). Nothing outside the array is read.
    ///
    /// When the ABI reports the name's length, pass it as `length`: the
    /// first `length` bytes are the name. A length the array cannot hold
    /// is a driver fault and answers nil rather than a guess.
    ///
    /// Without a length, the name runs to the first NUL, or to the end of
    /// the array if it has none.
    public static func bytes<Field>(of field: Field, length: Int? = nil) -> [UInt8]? {
        withUnsafeBytes(of: field) { bytes(in: $0, length: length) }
    }

    /// `bytes(of:length:)` over raw memory already bounded to the array.
    public static func bytes(in field: UnsafeRawBufferPointer, length: Int? = nil) -> [UInt8]? {
        guard let length else {
            let end = field.firstIndex(of: 0) ?? field.endIndex
            return Array(field[..<end])
        }
        guard (0...field.count).contains(length) else { return nil }
        return Array(field.prefix(length))
    }
}
