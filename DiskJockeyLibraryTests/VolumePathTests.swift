//
//  VolumePathTests.swift — a name that is not valid UTF-8 reaches Finder
//  and the driver as the bytes it has on disk (diskjockey#219).
//
//  The two names below differ in one byte that is not valid UTF-8 on its
//  own. Decoding either one repairs that byte to U+FFFD, so a lossy path
//  turns them into ONE name: shown twice, and openable as neither.
//

import FSKit
import Foundation
import Testing
@testable import DiskJockeyLibrary

private let cafE9: [UInt8] = Array("caf".utf8) + [0xE9] + Array(".txt".utf8)
private let cafEA: [UInt8] = Array("caf".utf8) + [0xEA] + Array(".txt".utf8)
private let slash = UInt8(ascii: "/")

/// What a `const char *` the driver receives holds, NUL excluded.
private func received(_ path: VolumePath) -> [UInt8] {
    path.withCString { ptr in
        var out: [UInt8] = []
        var p = ptr
        while p.pointee != 0 { out.append(UInt8(bitPattern: p.pointee)); p += 1 }
        return out
    }
}

@Suite("names that are not UTF-8")
struct NonUTF8NameTests {

    @Test func theFixtureNamesAreNotUTF8() {
        #expect(String(validatingUTF8: cafE9.map { CChar(bitPattern: $0) } + [0]) == nil)
        #expect(String(validatingUTF8: cafEA.map { CChar(bitPattern: $0) } + [0]) == nil)
    }

    @Test func theNameFinderIsGivenKeepsTheBytes() {
        #expect([UInt8](DirentName.fileName(cafE9).data) == cafE9)
    }

    @Test func twoNamesDifferingInAnInvalidByteStayTwoNames() {
        #expect(DirentName.fileName(cafE9).data != DirentName.fileName(cafEA).data)
    }

    @Test func aChildOfTheRootIsTheRootThenTheBytes() {
        #expect(VolumePath.root.appending(cafE9)?.bytes == [slash] + cafE9)
    }

    @Test func aDeeperChildKeepsEveryComponentsBytes() {
        let dir = VolumePath.root.appending([0xFF, 0x64])
        #expect(dir?.appending(cafE9)?.bytes == [slash, 0xFF, 0x64, slash] + cafE9)
    }

    @Test func theDriverReceivesTheOriginalBytes() throws {
        let path = try #require(VolumePath.root.appending(cafE9))
        #expect(received(path) == [slash] + cafE9)
    }

    @Test func aLookupNameFromFSKitIsJoinedByItsBytes() {
        let name = FSFileName(data: Data(cafEA))
        #expect(VolumePath.root.appending(name)?.bytes == [slash] + cafEA)
    }

    @Test func distinctNamesMakeDistinctPaths() {
        #expect(VolumePath.root.appending(cafE9) != VolumePath.root.appending(cafEA))
    }

    @Test func anItemMadeFromBytesKeepsThem() throws {
        let path = try #require(VolumePath.root.appending(cafE9))
        let item = SquashfsItem(inode: 7, volumePath: path, parentInode: 1)
        #expect(item.volumePath.bytes == [slash] + cafE9)
    }

    @Test func aSymlinkTargetComesBackAsItsBytes() throws {
        let target = Array("../".utf8) + cafE9
        let got = try SymlinkTarget.readBytes(lastErrno: { 0 }) { buf, size in
            for (i, b) in target.enumerated() { buf[i] = CChar(bitPattern: b) }
            buf[target.count] = 0
            return Int32(target.count)
        }
        #expect(got == target)
    }
}

@Suite("VolumePath")
struct VolumePathTests {

    @Test func aTextPathIsItsUTF8() {
        #expect(VolumePath("/etc/hosts").bytes == Array("/etc/hosts".utf8))
        #expect(VolumePath("/") == VolumePath.root)
    }

    @Test func anItemMadeFromTextHasTheSameBytes() {
        let item = SquashfsItem(inode: 3, path: "/usr/caf\u{e9}", parentInode: 1)
        #expect(item.volumePath == VolumePath("/usr/caf\u{e9}"))
    }

    @Test func aNameThatCannotBeOneComponentIsRefused() {
        #expect(VolumePath.root.appending([UInt8]()) == nil)
        #expect(VolumePath.root.appending(Array("a/b".utf8)) == nil)
        #expect(VolumePath.root.appending([0x61, 0x00, 0x62]) == nil)
    }

    @Test func theDriverGetsATerminatedCopyOfTheBytes() {
        #expect(received(VolumePath("/a/b")) == Array("/a/b".utf8))
    }

    @Test func theReadableFormShowsReplacementCharacters() throws {
        let path = try #require(VolumePath.root.appending(cafE9))
        #expect(path.description == "/caf\u{FFFD}.txt")
    }
}

/// What reaches a driver whose ABI decodes paths as UTF-8 — the pinned
/// erofs, ext4, btrfs and xfs releases. Two of them answer an undecodable
/// path as the root, so the only safe answer is not to send one.
@Suite("a path handed to a driver")
struct DriverPathEncodingTests {

    private func refusal(_ body: () throws -> VolumePath) -> Int32? {
        do { _ = try body(); return nil } catch let error as POSIXError {
            return error.code.rawValue
        } catch { return -1 }
    }

    @Test func aByteDriverGetsANameThatIsNotUTF8Unchanged() throws {
        let path = try VolumePath.root.child(cafE9, for: .bytes)
        #expect(received(path) == [slash] + cafE9)
    }

    @Test func aUTF8DriverIsNeverHandedANameThatIsNotUTF8() {
        #expect(refusal { try VolumePath.root.child(cafE9, for: .utf8) } == EILSEQ)
    }

    @Test func aUTF8DriverGetsAUTF8NameUnchanged() throws {
        let cafe = Array("caf\u{e9}.txt".utf8)
        let path = try VolumePath.root.child(cafe, for: .utf8)
        #expect(path.bytes == [slash] + cafe)
    }

    @Test func aChildOfANonUTF8DirectoryIsRefusedToo() throws {
        let dir = try VolumePath.root.child(cafE9, for: .bytes)
        #expect(refusal { try dir.child(Array("x".utf8), for: .utf8) } == EILSEQ)
    }

    @Test func aNameThatCannotBeOneComponentIsNotFound() {
        #expect(refusal { try VolumePath.root.child([UInt8](), for: .bytes) } == ENOENT)
        #expect(refusal { try VolumePath.root.child(Array("a/b".utf8), for: .bytes) } == ENOENT)
        #expect(refusal { try VolumePath.root.child([0x61, 0x00], for: .bytes) } == ENOENT)
    }

    @Test func aNameFromFSKitIsTakenByItsBytes() throws {
        let name = FSFileName(data: Data(cafEA))
        #expect(try VolumePath.root.child(name, for: .bytes).bytes == [slash] + cafEA)
        #expect(refusal { try VolumePath.root.child(name, for: .utf8) } == EILSEQ)
    }

    /// The forms Rust's str::from_utf8 refuses, each of which Swift's own
    /// String(decoding:) would repair rather than reject.
    @Test(arguments: [
        [0xE9] as [UInt8],             // a lone Latin-1 byte
        [0x80],                        // a stray continuation byte
        [0xE2, 0x82],                  // a truncated three-byte sequence
        [0xC0, 0xAF],                  // an overlong '/'
        [0xED, 0xA0, 0x80],            // an encoded surrogate, U+D800
        [0xF4, 0x90, 0x80, 0x80],      // past U+10FFFF
        [0xFF],
    ])
    func malformedUTF8IsNotValid(_ name: [UInt8]) {
        #expect(!VolumePath(bytes: [slash] + name).isValidUTF8)
    }

    @Test func wellFormedUTF8IsValid() {
        #expect(VolumePath.root.isValidUTF8)
        #expect(VolumePath("/caf\u{e9}/\u{1F4BE}").isValidUTF8)
    }

    @Test func theLastComponentIsTheNamesBytes() throws {
        let path = try VolumePath.root.child(Array("d".utf8), for: .bytes).child(cafE9, for: .bytes)
        #expect(path.lastComponent == cafE9)
        #expect(VolumePath.root.lastComponent == [])
    }

    @Test func aPathSpelledAsALiteralIsItsUTF8() {
        let path: VolumePath = "/etc/hosts"
        #expect(path == VolumePath("/etc/hosts"))
    }

    /// FSKit's own contract for a name that is not UTF-8: `data` always
    /// holds it, and it survives a round trip through FSFileName intact.
    @Test func anFSFileNameRoundTripsBytesThatAreNotUTF8() {
        for name in [cafE9, cafEA, [0xFF, 0xFE], Array("%E9".utf8)] {
            #expect([UInt8](DirentName.fileName(name).data) == name)
        }
    }
}
