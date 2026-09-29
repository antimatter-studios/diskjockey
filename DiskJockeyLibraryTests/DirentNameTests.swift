//
//  DirentNameTests.swift — a directory entry's name comes out of the
//  driver's fixed-size array whole, and nothing past the array is read.
//
//  The case that matters is SquashFS's (diskjockey#207): a name can be
//  256 bytes, so its array is 257, and a reader that believed 256 put
//  the terminator of a maximum-length name outside the region it had.
//

import Foundation
import Testing
@testable import DiskJockeyLibrary

/// `char name[257]` from fs_squashfs.h, as Swift imports it: a tuple of
/// 257 `CChar`s. Spelled out because the whole point is the real size.
private typealias SquashfsName = (
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar
)

/// A 4-byte `char name[4]`, for the edges.
private typealias Name4 = (CChar, CChar, CChar, CChar)

/// A value of the imported array type `T` holding `bytes`, zero-filled.
private func field<T>(_ bytes: [UInt8], as _: T.Type) -> T {
    precondition(bytes.count <= MemoryLayout<T>.size)
    let padded = bytes + [UInt8](repeating: 0, count: MemoryLayout<T>.size - bytes.count)
    return padded.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
}

struct DirentNameTests {

    private static let longest = [UInt8](repeating: UInt8(ascii: "n"), count: 256)

    @Test func theImportedSquashfsArrayIs257Bytes() {
        #expect(MemoryLayout<SquashfsName>.size == 257)
    }

    @Test func aMaximumLengthSquashfsNameIsReadWholeByItsLength() {
        let name = field(Self.longest + [0], as: SquashfsName.self)
        #expect(DirentName.bytes(of: name, length: 256) == Self.longest)
    }

    @Test func aMaximumLengthSquashfsNameIsReadWholeByItsTerminator() {
        let name = field(Self.longest + [0], as: SquashfsName.self)
        #expect(DirentName.bytes(of: name) == Self.longest)
    }

    @Test func theLengthIsACountNotAScan() {
        let name = field(Array("abc".utf8), as: Name4.self)
        #expect(DirentName.bytes(of: name, length: 2) == Array("ab".utf8))
        #expect(DirentName.bytes(of: name, length: 0) == [])
    }

    @Test func anUnterminatedArrayEndsAtItsOwnSize() {
        let name = field(Array("wxyz".utf8), as: Name4.self)
        #expect(DirentName.bytes(of: name) == Array("wxyz".utf8))
        #expect(DirentName.bytes(of: name, length: 4) == Array("wxyz".utf8))
    }

    @Test func aLengthTheArrayCannotHoldIsRefused() {
        let name = field(Array("wxyz".utf8), as: Name4.self)
        #expect(DirentName.bytes(of: name, length: 5) == nil)
        #expect(DirentName.bytes(of: name, length: -1) == nil)
        let squashfs = field(Self.longest + [0], as: SquashfsName.self)
        #expect(DirentName.bytes(of: squashfs, length: 258) == nil)
    }

    @Test func bytesThatAreNotUTF8ComeBackUnchanged() {
        let raw: [UInt8] = [0x63, 0x61, 0x66, 0xE9, 0x2E, 0x74, 0x78, 0x74] // "caf\xE9.txt"
        let name = field(raw, as: SquashfsName.self)
        #expect(DirentName.bytes(of: name, length: raw.count) == raw)
        #expect(DirentName.bytes(of: name) == raw)
    }
}
