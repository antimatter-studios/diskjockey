//
//  SymlinkTargetTests.swift — the readlink return-value contract every
//  driver shares: a length on success, -1 with errno on failure.
//
//  The buffers below are laid out the way a driver leaves them, so the
//  tests pin what the volumes do with a real call's result.
//

import Foundation
import Testing
@testable import DiskJockeyLibrary

/// A buffer as a driver leaves it after writing `target` and a NUL.
private func written(_ target: String, capacity: Int = 64) -> [CChar] {
    var buf = [CChar](repeating: 0, count: capacity)
    for (i, byte) in target.utf8.enumerated() { buf[i] = CChar(bitPattern: byte) }
    return buf
}

/// A stand-in for fs_<fs>_readlink over a fixed target, honouring the
/// contract: ERANGE and nothing written when the buffer is too small.
private final class FakeDriver {
    let target: [UInt8]
    var errno: Int32 = 0
    var capacities: [Int] = []

    init(_ target: String) { self.target = Array(target.utf8) }

    func readlink(_ buf: UnsafeMutablePointer<CChar>, _ size: Int) -> Int32 {
        capacities.append(size)
        guard size >= target.count + 1 else {
            errno = ERANGE
            return -1
        }
        for (i, byte) in target.enumerated() { buf[i] = CChar(bitPattern: byte) }
        buf[target.count] = 0
        errno = 0
        return Int32(target.count)
    }
}

@Suite("readlink outcome")
struct ReadlinkOutcomeTests {

    /// Success is the target's length, not zero.
    @Test func aLengthIsSuccess() {
        let r = SymlinkTarget.outcome(rc: 11, buffer: written("../etc/host"), errno: 0)
        #expect(r == .target("../etc/host"))
    }

    /// The length is what bounds the target, not the first NUL.
    @Test func theLengthBoundsTheTarget() {
        var buf = written("abcdef")
        buf[3] = 0x78 // "abcxef": the length is authoritative either way
        #expect(SymlinkTarget.outcome(rc: 3, buffer: buf, errno: 0) == .target("abc"))
    }

    /// A zero-length target is a success, not an error.
    @Test func zeroIsAnEmptyTarget() {
        #expect(SymlinkTarget.outcome(rc: 0, buffer: written(""), errno: 0) == .target(""))
    }

    /// Multi-byte UTF-8 survives: the length counts bytes, not characters.
    @Test func utf8TargetsAreDecodedByByteLength() {
        let t = "caf\u{e9}/\u{1F4BE}"
        let r = SymlinkTarget.outcome(rc: Int32(t.utf8.count), buffer: written(t), errno: 0)
        #expect(r == .target(t))
    }

    @Test func erangeAsksForABiggerBuffer() {
        #expect(SymlinkTarget.outcome(rc: -1, buffer: written(""), errno: ERANGE) == .bufferTooSmall)
    }

    @Test func otherErrorsCarryTheirErrno() {
        #expect(SymlinkTarget.outcome(rc: -1, buffer: written(""), errno: EINVAL) == .failed(errno: EINVAL))
        #expect(SymlinkTarget.outcome(rc: -1, buffer: written(""), errno: ENOENT) == .failed(errno: ENOENT))
    }

    /// A failure with no errno is still a failure, reported as EIO.
    @Test func aFailureWithoutErrnoIsEIO() {
        #expect(SymlinkTarget.outcome(rc: -1, buffer: written(""), errno: 0) == .failed(errno: EIO))
    }

    /// A length the buffer could not hold is a driver fault, not a target.
    @Test func aLengthPastTheBufferIsEIO() {
        #expect(SymlinkTarget.outcome(rc: 64, buffer: written("x", capacity: 64), errno: 0) == .failed(errno: EIO))
    }
}

@Suite("readlink retry")
struct ReadlinkRetryTests {

    @Test func aShortTargetIsReadInOneCall() throws {
        let d = FakeDriver("/usr/lib")
        let t = try SymlinkTarget.read(lastErrno: { d.errno }) { d.readlink($0, $1) }
        #expect(t == "/usr/lib")
        #expect(d.capacities == [SymlinkTarget.initialCapacity])
    }

    /// ERANGE grows the buffer until the target fits, never truncating.
    @Test func erangeRetriesWithALargerBuffer() throws {
        let long = String(repeating: "a/", count: 5000) // 10000 bytes
        let d = FakeDriver(long)
        let t = try SymlinkTarget.read(lastErrno: { d.errno }) { d.readlink($0, $1) }
        #expect(t == long)
        #expect(d.capacities == [4096, 8192, 16384])
    }

    /// A target no buffer up to the maximum can hold is refused clearly.
    @Test func aTargetPastTheMaximumIsENAMETOOLONG() {
        let d = FakeDriver(String(repeating: "x", count: 100))
        #expect(throws: POSIXError(.ENAMETOOLONG)) {
            try SymlinkTarget.read(initialCapacity: 16, maximumCapacity: 64,
                                   lastErrno: { d.errno }) { d.readlink($0, $1) }
        }
        #expect(d.capacities == [16, 32, 64])
    }

    @Test func otherErrorsAreThrownAsTheirErrno() {
        #expect(throws: POSIXError(.EINVAL)) {
            try SymlinkTarget.read(lastErrno: { EINVAL }) { _, _ in -1 }
        }
    }

    /// A volume that maps errno its own way gets the errno, not EIO.
    @Test func theErrorMappingIsTheCallersChoice() {
        struct Mapped: Error, Equatable { let code: Int32 }
        #expect(throws: Mapped(code: ENOENT)) {
            try SymlinkTarget.read(lastErrno: { ENOENT }, error: { Mapped(code: $0) }) { _, _ in -1 }
        }
    }
}
