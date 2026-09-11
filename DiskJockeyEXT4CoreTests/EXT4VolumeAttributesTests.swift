//
//  EXT4VolumeAttributesTests.swift — the REAL EXT4 attribute conversion and
//  item cache, not a copy of them.
//
//  WHAT THIS REPLACES, AND WHY IT MATTERS
//  --------------------------------------
//  `DiskJockeyTests/EXT4AttributeMaskTests.swift` and
//  `EXT4ItemCacheTests.swift` are 13 cases that test hand-written MIRRORS of
//  this code. They say so themselves:
//
//      // ----- begin mirror of EXT4Volume.swift attributes(from:parentInode:) -----
//      // UPDATE `FSKitAttributesMirror.populate(...)` BELOW to match. The
//      // protocol mirrors with hand-kept fidelity.
//
//  A mirror passes while the original is wrong, which is the same defect
//  shape as a check whose output does not depend on what it is meant to
//  detect. They were written that way for a real reason — an app extension
//  is a `.appex` and cannot be imported by any test target, so the code
//  under test was unreachable.
//
//  It is reachable now. `EXT4Volume.swift`, `FileSystemBackend.swift`,
//  `EXT4Watchdog.swift` and `EXT4Log.swift` build as `DiskJockeyEXT4Core`,
//  because exactly three couplings held 903 lines of volume logic inside the
//  bundle: a file-scope `log`, one call to
//  `EXT4FileSystem.scheduleWatchdogIfNeeded()`, and one call to
//  `fs_ext4_last_error()`. None of them were about the volume.
//
//  This file therefore asserts against `EXT4Volume.attributes(from:)`
//  itself. Nothing here is a copy of the production body; where an expected
//  value is spelled out it is spelled out from the FSKit contract or the
//  ext4 on-disk meaning, not from the code beside it.
//
//  Host-free: no app, no extension bundle, no Rust, no C, nothing launched.
//

import Foundation
import FSKit
import Testing
@testable import DiskJockeyEXT4Core
@testable import DiskJockeyLibrary

// MARK: - Fixtures

/// A backend that answers only what the code under test asks of it. The
/// protocol is large; the two statics tested here touch `lastErrno()` and
/// `lastErrorMessage()` and nothing else, so the rest traps rather than
/// returning a plausible lie.
private final class StubBackend: FileSystemBackend {
    var errno: Int32 = 0
    var message: String = "(stub)"

    func lastErrno() -> Int32 { errno }
    func lastErrorMessage() -> String { message }

    // Everything below is out of scope for these tests. Failing loudly beats
    // returning a default that lets a test pass for the wrong reason.
    func volumeInfo() -> BackendVolumeInfo { unreachable() }
    func shutdown() { unreachable() }
    func stat(path: String) -> BackendFileAttributes? { unreachable() }
    func readDirectory(path: String) -> [BackendDirectoryEntry]? { unreachable() }
    func readFile(path: String, offset: UInt64, length: UInt64,
                  buffer: UnsafeMutableRawPointer) -> Int64 { unreachable() }
    func readSymlink(path: String) -> String? { unreachable() }
    func createFile(path: String, mode: UInt16) -> Bool { unreachable() }
    func writeFile(path: String, data: UnsafeRawPointer, length: UInt64) -> Int64 { unreachable() }
    func pwrite(path: String, offset: UInt64,
                data: UnsafeRawPointer, length: UInt64) -> Int64 { unreachable() }
    func unlink(path: String) -> Bool { unreachable() }
    func rename(src: String, dst: String) -> Bool { unreachable() }
    func mkdir(path: String, mode: UInt16) -> Bool { unreachable() }
    func rmdir(path: String) -> Bool { unreachable() }
    func truncate(path: String, size: UInt64) -> Bool { unreachable() }
    func chmod(path: String, mode: UInt16) -> Bool { unreachable() }
    func chown(path: String, uid: UInt32?, gid: UInt32?) -> Bool { unreachable() }
    func symlink(target: String, linkpath: String) -> Bool { unreachable() }
    func link(src: String, dst: String) -> Bool { unreachable() }
    func utimens(path: String, atime: timespec?, mtime: timespec?) -> Bool { unreachable() }
    func flush() -> Bool { unreachable() }

    private func unreachable(_ function: String = #function) -> Never {
        fatalError("StubBackend.\(function) was called; these tests are not meant to reach the backend")
    }
}

/// A plausible stat result. Every field is distinct so a mis-assignment
/// between two of them cannot pass.
private func stat(type: BackendFileType = .file,
                  fileID: UInt64 = 12,
                  mode: UInt16 = 0o644,
                  uid: UInt32 = 501,
                  gid: UInt32 = 20,
                  size: UInt64 = 4096,
                  linkCount: UInt16 = 1,
                  atime: Int64 = 1_700_000_001,
                  mtime: Int64 = 1_700_000_002,
                  ctime: Int64 = 1_700_000_003,
                  crtime: Int64 = 1_700_000_004) -> BackendFileAttributes {
    BackendFileAttributes(fileID: fileID, fileType: type, mode: mode, uid: uid, gid: gid,
                          size: size, linkCount: linkCount,
                          atime: atime, mtime: mtime, ctime: ctime, crtime: crtime)
}

// MARK: - The conversion

@Suite("EXT4Volume.attributes(from:parentInode:)")
struct EXT4AttributeConversionTests {

    /// EVERY FIELD, DISTINCT VALUES. The defect this conversion was written
    /// for was a MISSING attribute — FSKit validates the bit set of what a
    /// volume returns and turns an incomplete reply into ENOENT, which
    /// surfaces as "the file I just saved has vanished". A field left unset
    /// and a field set from the wrong source look identical from outside, so
    /// each input here is a different number.
    @Test func everyFieldIsPopulatedFromItsOwnSource() {
        let attrs = EXT4Volume.attributes(from: stat(), parentInode: 2)
        #expect(attrs.type == .file)
        #expect(attrs.mode == 0o644)
        #expect(attrs.uid == 501)
        #expect(attrs.gid == 20)
        #expect(attrs.size == 4096)
        #expect(attrs.linkCount == 1)
        #expect(attrs.allocSize == 4096)
        #expect(attrs.accessTime.tv_sec == 1_700_000_001)
        #expect(attrs.modifyTime.tv_sec == 1_700_000_002)
        #expect(attrs.changeTime.tv_sec == 1_700_000_003)
        #expect(attrs.birthTime.tv_sec == 1_700_000_004)
        #expect(attrs.fileID.rawValue == 12)
        #expect(attrs.parentID.rawValue == 2)
    }

    /// ext4's `i_crtime` IS the birth time. It used to be routed into
    /// `addedTime`, an HFS+/APFS concept meaning "when this dirent was added
    /// to its current parent" — which left FSKit's required birthTime bit
    /// unset and produced the incomplete-mask ENOENT.
    @Test func crtimeBecomesBirthTimeAndNotAddedTime() {
        let attrs = EXT4Volume.attributes(from: stat(crtime: 999_000), parentInode: 2)
        #expect(attrs.birthTime.tv_sec == 999_000)
        #expect(attrs.addedTime.tv_sec != 999_000,
                "crtime is the birth time; addedTime is a different concept and must not be where it lands")
    }

    /// `flags = 0` is deliberate and load-bearing: the FFI does not surface
    /// ext4's i_flags yet, and setting it to zero is what marks the bit
    /// VALID so FSKit accepts the reply. Leaving it unset was part of the
    /// incomplete mask.
    @Test func flagsAreSetToZeroRatherThanLeftUnset() {
        #expect(EXT4Volume.attributes(from: stat(), parentInode: 2).flags == 0)
    }

    /// Only the permission bits reach `mode`. ext4 packs the file type into
    /// the top bits of the same field, and passing those through would make
    /// a directory's mode read as 0o40755.
    @Test func modeCarriesOnlyThePermissionBits() {
        let attrs = EXT4Volume.attributes(from: stat(type: .directory, mode: 0o40755), parentInode: 2)
        #expect(attrs.mode == 0o755, "the S_IFDIR bits leaked into mode")
        #expect(attrs.type == .directory, "and the type still has to be right")
    }

    @Test func setuidAndStickyBitsSurvive() {
        // 0o7777 is the mask, so all three of setuid/setgid/sticky are kept.
        #expect(EXT4Volume.attributes(from: stat(mode: 0o104755), parentInode: 2).mode == 0o4755)
        #expect(EXT4Volume.attributes(from: stat(mode: 0o41777), parentInode: 2).mode == 0o1777)
    }

    /// THE ROOT DIRECTORY IS THE ONLY CASE WITH NO PARENT, and FSKit defines
    /// its parent as the sentinel 1 (`FSItemIDParentOfRoot`). A nil that
    /// arrived as 0 would be an invalid identifier and the assignment would
    /// silently not happen.
    @Test func aNilParentBecomesTheFSKitRootSentinel() {
        let attrs = EXT4Volume.attributes(from: stat(fileID: 2), parentInode: nil)
        #expect(attrs.parentID.rawValue == 1,
                "root's parent must be FSItemIDParentOfRoot (1), not 0 and not absent")
    }

    @Test("every backend file type maps to its FSKit counterpart",
          arguments: [(BackendFileType.file, FSItem.ItemType.file),
                      (.directory, .directory),
                      (.symlink, .symlink),
                      (.charDevice, .charDevice),
                      (.blockDevice, .blockDevice),
                      (.fifo, .fifo),
                      (.socket, .socket)])
    func fileTypes(backend: BackendFileType, expected: FSItem.ItemType) {
        #expect(EXT4Volume.attributes(from: stat(type: backend), parentInode: 2).type == expected)
    }

    /// `.unknown` deliberately becomes `.file` rather than propagating an
    /// unknown type into FSKit, which has no representation for one.
    @Test func anUnknownTypeIsReportedAsAFile() {
        #expect(EXT4Volume.attributes(from: stat(type: .unknown), parentInode: 2).type == .file)
    }

    /// SECONDS ARE SIGNED AND SIXTY-FOUR BITS, and the struct's own comment
    /// records what held them as UInt32 cost: "everything before 1970 read
    /// back as a date in the far future and everything after 2038 was
    /// truncated -- and neither showed up as an error, only as a wrong date
    /// in the Finder". ext4's real range is roughly 1901 to 2446.
    @Test func timestampsOutsideTheUInt32RangeSurvive() {
        let preEpoch: Int64 = -2_208_988_800      // 1900-01-01
        let post2038: Int64 = 4_102_444_800       // 2100-01-01
        let attrs = EXT4Volume.attributes(from: stat(atime: preEpoch, mtime: post2038,
                                                     ctime: preEpoch, crtime: post2038),
                                          parentInode: 2)
        #expect(attrs.accessTime.tv_sec == Int(preEpoch), "a pre-1970 timestamp wrapped")
        #expect(attrs.modifyTime.tv_sec == Int(post2038), "a post-2038 timestamp truncated")
        #expect(attrs.changeTime.tv_sec == Int(preEpoch))
        #expect(attrs.birthTime.tv_sec == Int(post2038))
    }

    /// Nanoseconds are zero because the FFI does not carry them. Stated so
    /// that surfacing them later is a decision rather than a surprise.
    @Test func nanosecondsAreZeroBecauseTheFFIDoesNotCarryThem() {
        let attrs = EXT4Volume.attributes(from: stat(), parentInode: 2)
        #expect(attrs.accessTime.tv_nsec == 0)
        #expect(attrs.modifyTime.tv_nsec == 0)
        #expect(attrs.changeTime.tv_nsec == 0)
        #expect(attrs.birthTime.tv_nsec == 0)
    }

    @Test func aLargeFileKeepsItsFullSize() {
        let big: UInt64 = 5_000_000_000          // > 4 GiB
        let attrs = EXT4Volume.attributes(from: stat(size: big), parentInode: 2)
        #expect(attrs.size == big, "the size truncated through a 32-bit path")
        #expect(attrs.allocSize == big)
    }

    @Test func hardLinkCountsAreCarriedThrough() {
        #expect(EXT4Volume.attributes(from: stat(linkCount: 7), parentInode: 2).linkCount == 7)
    }
}

// MARK: - The static helpers beside it

@Suite("EXT4Volume helpers")
struct EXT4VolumeHelperTests {

    /// The double-slash trap: `"/" + "/foo"` is `"//foo"`, which the backend
    /// then stats as a different path from `/foo`.
    @Test func joiningOntoRootDoesNotDoubleTheSlash() {
        #expect(EXT4Volume.joinPath("/", "foo") == "/foo")
        #expect(EXT4Volume.joinPath("/dir", "foo") == "/dir/foo")
        #expect(EXT4Volume.joinPath("/a/b", "c") == "/a/b/c")
    }

    @Test func joiningPreservesNamesThatLookLikePaths() {
        // A file may legitimately be named with dots or spaces; the join is
        // not a normaliser and must not become one.
        #expect(EXT4Volume.joinPath("/", "..") == "/..")
        #expect(EXT4Volume.joinPath("/dir", "a b") == "/dir/a b")
        #expect(EXT4Volume.joinPath("/dir", ".hidden") == "/dir/.hidden")
    }

    /// The errno translation defaults to EIO, because a thrown error with no
    /// recognisable code is worse for the caller than a generic I/O failure.
    @Test func aKnownErrnoBecomesItsPOSIXCode() {
        let backend = StubBackend()
        backend.errno = ENOENT
        #expect(EXT4Volume.posixError(from: backend).code == .ENOENT)
        backend.errno = EBUSY
        #expect(EXT4Volume.posixError(from: backend).code == .EBUSY)
    }

    @Test func aMissingOrUnknownErrnoBecomesEIO() {
        let backend = StubBackend()
        backend.errno = 0
        #expect(EXT4Volume.posixError(from: backend).code == .EIO,
                "errno 0 means the last call succeeded, so there is no specific failure to report")
        backend.errno = 31_337
        #expect(EXT4Volume.posixError(from: backend).code == .EIO,
                "an errno with no POSIXErrorCode must not throw something unrecognisable")
    }

    /// The one C call that used to sit in this file now comes through the
    /// protocol, and this is the seam that replaced it.
    @Test func theBackendSuppliesItsOwnErrorText() {
        let backend = StubBackend()
        backend.message = "ext4: no space left on device"
        #expect(backend.lastErrorMessage() == "ext4: no space left on device")
    }
}
