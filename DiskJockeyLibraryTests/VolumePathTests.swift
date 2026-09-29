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
