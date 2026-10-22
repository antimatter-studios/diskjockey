//
//  XfsAttributeTests.swift — FSKit attribute and extended attribute changes
//  on XFS (diskjockey#328).
//
//  setAttributes mapped only a size change, and the volume answered no
//  extended attribute request at all. rust-fs-xfs 0.13 logs mode, owner and
//  time changes in one call (fs_xfs_set_attributes) and stores extended
//  attributes in its user, trusted and security namespaces
//  (fs_xfs_setxattr and the rest). These tests hold the volume to:
//
//  - mode, owner and both times in one driver call, beside a size change;
//  - a field the ABI cannot set refused whole, before anything is written;
//  - a macOS extended attribute stored under XFS's user namespace, the
//    FSKit set policies mapped to the driver's CREATE and REPLACE flags,
//    and the driver's errno for every refusal;
//  - macOS's own ACL attribute refused, since storing it as a POSIX ACL or
//    as plain bytes would change what it means.
//

import Foundation
import FSKit
import Testing
@testable import DiskJockeyXFSCore
import DiskJockeyLibrary

private final class AttrDriver: XfsMountedVolumeDriver {
    var isWritable = true
    var errno: Int32 = 0
    var size: UInt64 = 11
    private(set) var attributeCalls: [(mode: UInt32?, uid: UInt32?, gid: UInt32?,
                                       accessed: timespec?, modified: timespec?)] = []
    private(set) var truncates: [(UInt64, timespec?)] = []
    /// The file's extended attributes, by their XFS name.
    var xattrs: [String: [UInt8]] = ["user.kept": Array("v".utf8),
                                     "trusted.hidden": [1],
                                     "security.selinux": [2]]
    private(set) var xattrCalls: [String] = []

    func setAttributes(_ path: VolumePath, mode: UInt32?, uid: UInt32?, gid: UInt32?,
                       accessed: timespec?, modified: timespec?) -> Int32 {
        attributeCalls.append((mode, uid, gid, accessed, modified))
        return 0
    }

    func truncate(_ path: VolumePath, to size: UInt64, modified: timespec?) -> Int32 {
        truncates.append((size, modified))
        self.size = size
        return 0
    }

    func getXattr(_ path: VolumePath, name: [UInt8]) -> [UInt8]? {
        guard let v = xattrs[String(decoding: name, as: UTF8.self)] else { errno = ENOATTR; return nil }
        return v
    }

    func listXattrs(_ path: VolumePath) -> [[UInt8]]? {
        xattrs.keys.sorted().map { Array($0.utf8) }
    }

    func setXattr(_ path: VolumePath, name: [UInt8], value: [UInt8], flags: Int32) -> Int32 {
        let key = String(decoding: name, as: UTF8.self)
        xattrCalls.append("set \(key) \(flags)")
        if flags == 1, xattrs[key] != nil { errno = EEXIST; return -1 }
        if flags == 2, xattrs[key] == nil { errno = ENOATTR; return -1 }
        xattrs[key] = value
        return 0
    }

    func removeXattr(_ path: VolumePath, name: [UInt8]) -> Int32 {
        let key = String(decoding: name, as: UTF8.self)
        xattrCalls.append("remove \(key)")
        guard xattrs.removeValue(forKey: key) != nil else { errno = ENOATTR; return -1 }
        return 0
    }

    func stat(_ path: VolumePath) -> ReadOnlyFileAttributes? {
        ReadOnlyFileAttributes(inode: 128, mode: 0o100644, uid: 0, gid: 0, size: size,
                               linkCount: 1, mtime: 0, fileType: .file)
    }

    func volumeInfo() -> ReadOnlyVolumeInfo? { nil }
    func walkDirectory(_ path: VolumePath,
                       _ visit: (ReadOnlyDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk { .finished }
    func read(_ path: VolumePath, at offset: UInt64,
              into buffer: UnsafeMutableRawBufferPointer) -> Int64 { 0 }
    func write(_ path: VolumePath, at offset: UInt64,
               from buffer: UnsafeRawBufferPointer) -> Int64 { -1 }
    func flush() -> Int32 { 0 }
    func create(_ path: VolumePath, mode: UInt16) -> UInt64 { errno = ENOTSUP; return 0 }
    func mkdir(_ path: VolumePath, mode: UInt16) -> UInt64 { errno = ENOTSUP; return 0 }
    func unlink(_ path: VolumePath) -> Int32 { errno = ENOTSUP; return -1 }
    func rmdir(_ path: VolumePath) -> Int32 { errno = ENOTSUP; return -1 }
    func link(_ source: VolumePath, to destination: VolumePath) -> Int32 { errno = ENOTSUP; return -1 }
    func rename(_ source: VolumePath, to destination: VolumePath, replace: Bool) -> Int32 { errno = ENOTSUP; return -1 }
    func readlink(_ path: VolumePath, _ buffer: UnsafeMutablePointer<CChar>, _ size: Int) -> Int32 { -1 }
    func lastErrno() -> Int32 { errno }
    func unmount() { isWritable = false }
}

private let filePath = VolumePath(bytes: Array("/f".utf8))
private func name(_ s: String) -> FSFileName { FSFileName(string: s) }

private func fixture(writable: Bool = true) throws -> (XfsVolume, AttrDriver, XfsItem) {
    let driver = AttrDriver()
    let access = writable
        ? try XfsMountPolicy.readWrite.authorize(deviceIsWritable: true, mountedDriver: .success(true))
        : .readOnly
    let volume = XfsVolume(volumeID: FSVolume.Identifier(), volumeName: FSFileName(string: "attr"),
                           driver: driver, contextPtr: nil, bsdName: "attr-test",
                           stats: IOStatsCollector(label: "attr-test", emit: { _ in }),
                           mountAccess: access)
    return (volume, driver, volume.item(forInode: 128, path: filePath, parentInode: 64))
}

private func code(_ body: () async throws -> Void) async -> POSIXErrorCode? {
    do { try await body(); return nil } catch let e as POSIXError { return e.code } catch { return nil }
}

@Suite("XFS attribute and extended attribute changes")
struct XfsAttributeTests {

    /// rust-fs-xfs frees an inode with its last name, so a file unlinked
    /// while open would be unreadable through its open handle. FSKit keeps
    /// such a file for its handles when the volume asks it to emulate
    /// open-unlink (diskjockey#354), writable or not: FSKit reads the
    /// property once, after the resource loads. Through the Objective-C
    /// runtime, since the property is optional and macOS 26's.
    @Test(arguments: [true, false])
    func theVolumeAsksFSKitToEmulateOpenUnlink(writable: Bool) throws {
        let (volume, _, _) = try fixture(writable: writable)
        let property = "enableOpenUnlinkEmulation"
        guard volume.responds(to: NSSelectorFromString(property)) else {
            Issue.record("XfsVolume does not implement \(property), so FSKit never emulates open-unlink")
            return
        }
        #expect(volume.value(forKey: property) as? Bool == true)
    }

    /// A volume that cannot write asks FSKit for a read-only mount, so
    /// Finder shows it read-only rather than letting every write fail with
    /// EROFS (diskjockey#354); a writable volume asks for nothing. Through
    /// the Objective-C runtime too: the property and its type are the macOS
    /// 26.4 SDK's, where `FSMountOptionsReadOnly` is 1.
    @Test(arguments: [true, false])
    func aVolumeThatCannotWriteAsksFSKitForAReadOnlyMount(writable: Bool) throws {
        let (volume, _, _) = try fixture(writable: writable)
        let property = "requestedMountOptions"
        guard volume.responds(to: NSSelectorFromString(property)) else {
            Issue.record("XfsVolume does not implement \(property), so a volume that cannot write mounts as writable")
            return
        }
        #expect((volume.value(forKey: property) as? NSNumber)?.uintValue == (writable ? 0 : 1))
    }

    @Test func modeOwnerAndTimesAreOneDriverCall() async throws {
        let (volume, driver, item) = try fixture()
        let request = FSItem.SetAttributesRequest()
        request.mode = 0o600
        request.uid = 501
        request.gid = 20
        request.accessTime = timespec(tv_sec: 100, tv_nsec: 1)
        request.modifyTime = timespec(tv_sec: -86400, tv_nsec: 2)
        _ = try await volume.setAttributes(request, on: item)
        #expect(driver.attributeCalls.count == 1)
        let call = try #require(driver.attributeCalls.first)
        #expect(call.mode == 0o600 && call.uid == 501 && call.gid == 20)
        #expect(call.accessed?.tv_sec == 100 && call.accessed?.tv_nsec == 1)
        #expect(call.modified?.tv_sec == -86400 && call.modified?.tv_nsec == 2)
        for field: FSItem.Attribute in [.mode, .uid, .gid, .accessTime, .modifyTime] {
            #expect(request.wasAttributeConsumed(field), "\(field)")
        }
        #expect(driver.truncates.isEmpty)
    }

    /// The type bits are not an attribute: chmod changes permission bits.
    @Test func onlyThePermissionBitsOfAModeAreSet() async throws {
        let (volume, driver, item) = try fixture()
        let request = FSItem.SetAttributesRequest()
        request.mode = 0o104755
        _ = try await volume.setAttributes(request, on: item)
        #expect(driver.attributeCalls.first?.mode == 0o4755)
        #expect(driver.attributeCalls.first?.uid == nil)
    }

    /// A size goes through truncate, which stamps the modification time in
    /// its own record; the rest of the request is set beside it.
    @Test func aSizeAndAModeAreBothApplied() async throws {
        let (volume, driver, item) = try fixture()
        let request = FSItem.SetAttributesRequest()
        request.size = 3
        request.mode = 0o640
        _ = try await volume.setAttributes(request, on: item)
        #expect(driver.truncates.map(\.0) == [3])
        #expect(driver.attributeCalls.first?.mode == 0o640)
        #expect(driver.attributeCalls.first?.modified == nil, "truncate stamps the time")
        #expect(request.wasAttributeConsumed(.size) && request.wasAttributeConsumed(.mode))
    }

    @Test func invalidAccessTimeNanosecondsAreRefusedBeforeAnyDriverCall() async throws {
        for nanoseconds in [-1, 1_000_000_000] {
            let (volume, driver, item) = try fixture()
            let request = FSItem.SetAttributesRequest()
            request.accessTime = timespec(tv_sec: 1, tv_nsec: nanoseconds)
            #expect(await code { _ = try await volume.setAttributes(request, on: item) } == .EINVAL)
            #expect(driver.attributeCalls.isEmpty && driver.truncates.isEmpty)
            #expect(!request.wasAttributeConsumed(.accessTime))
        }
    }

    @Test func invalidModificationNanosecondsAreRefusedBeforeAnyDriverCall() async throws {
        for nanoseconds in [-1, 1_000_000_000] {
            let (volume, driver, item) = try fixture()
            let request = FSItem.SetAttributesRequest()
            request.modifyTime = timespec(tv_sec: 1, tv_nsec: nanoseconds)
            #expect(await code { _ = try await volume.setAttributes(request, on: item) } == .EINVAL)
            #expect(driver.attributeCalls.isEmpty && driver.truncates.isEmpty)
            #expect(!request.wasAttributeConsumed(.modifyTime))
        }
    }

    @Test func invalidModificationNanosecondsDoNotReachTheSizePath() async throws {
        for nanoseconds in [-1, 1_000_000_000] {
            let (volume, driver, item) = try fixture()
            let request = FSItem.SetAttributesRequest()
            request.size = 3
            request.modifyTime = timespec(tv_sec: 1, tv_nsec: nanoseconds)
            #expect(await code { _ = try await volume.setAttributes(request, on: item) } == .EINVAL)
            #expect(driver.attributeCalls.isEmpty && driver.truncates.isEmpty)
            #expect(!request.wasAttributeConsumed(.size) && !request.wasAttributeConsumed(.modifyTime))
        }
    }

    /// The ABI sets none of these. A request carrying one is refused whole,
    /// before anything is written.
    @Test(arguments: [FSItem.Attribute.flags, .birthTime, .backupTime, .addedTime])
    func aFieldTheDriverCannotSetRefusesTheWholeRequest(_ field: FSItem.Attribute) async throws {
        let (volume, driver, item) = try fixture()
        let request = FSItem.SetAttributesRequest()
        request.mode = 0o600
        switch field {
        case .flags: request.flags = 2
        case .birthTime: request.birthTime = timespec(tv_sec: 1, tv_nsec: 0)
        case .backupTime: request.backupTime = timespec(tv_sec: 1, tv_nsec: 0)
        default: request.addedTime = timespec(tv_sec: 1, tv_nsec: 0)
        }
        #expect(await code { _ = try await volume.setAttributes(request, on: item) } == .ENOTSUP)
        #expect(driver.attributeCalls.isEmpty && driver.truncates.isEmpty)
    }

    @Test func aReadOnlyMountSetsNothing() async throws {
        let (volume, driver, item) = try fixture(writable: false)
        let request = FSItem.SetAttributesRequest()
        request.mode = 0o600
        #expect(await code { _ = try await volume.setAttributes(request, on: item) } == .EROFS)
        #expect(await code { try await volume.setXattr(named: name("a"), to: Data([1]), on: item, policy: .alwaysSet) } == .EROFS)
        #expect(driver.attributeCalls.isEmpty && driver.xattrCalls.isEmpty)
    }

    // MARK: - Extended attributes

    @Test func aMacAttributeIsStoredInTheUserNamespace() async throws {
        let (volume, driver, item) = try fixture()
        try await volume.setXattr(named: name("com.example.tag"), to: Data("red".utf8),
                                  on: item, policy: .alwaysSet)
        #expect(driver.xattrCalls == ["set user.com.example.tag 0"])
        let back = try await volume.xattr(named: name("com.example.tag"), of: item)
        #expect(back == Data("red".utf8))
    }

    /// Only the user namespace is a macOS caller's; trusted and security
    /// attributes are not listed.
    @Test func theListIsTheUserNamespaceWithoutItsPrefix() async throws {
        let (volume, _, item) = try fixture()
        let names = try await volume.xattrs(of: item).compactMap(\.string)
        #expect(names == ["kept"])
    }

    @Test func theSetPoliciesAreTheDriversFlags() async throws {
        let (volume, driver, item) = try fixture()
        try await volume.setXattr(named: name("new"), to: Data([1]), on: item, policy: .mustCreate)
        try await volume.setXattr(named: name("kept"), to: Data([2]), on: item, policy: .mustReplace)
        try await volume.setXattr(named: name("kept"), to: nil, on: item, policy: .delete)
        #expect(driver.xattrCalls == ["set user.new 1", "set user.kept 2", "remove user.kept"])
    }

    @Test func eachRefusalIsTheDriversErrno() async throws {
        let (volume, _, item) = try fixture()
        #expect(await code { _ = try await volume.xattr(named: name("absent"), of: item) } == .ENOATTR)
        #expect(await code { try await volume.setXattr(named: name("kept"), to: Data([1]), on: item, policy: .mustCreate) } == .EEXIST)
        #expect(await code { try await volume.setXattr(named: name("absent"), to: Data([1]), on: item, policy: .mustReplace) } == .ENOATTR)
        #expect(await code { try await volume.setXattr(named: name("absent"), to: nil, on: item, policy: .delete) } == .ENOATTR)
    }

    /// macOS hands an ACL over as com.apple.system.Security, an NFSv4-style
    /// ACL. Stored as a POSIX ACL or as plain bytes it would change meaning,
    /// so it is refused and nothing is written.
    @Test func macOSsACLAttributeIsRefused() async throws {
        let (volume, driver, item) = try fixture()
        #expect(await code {
            try await volume.setXattr(named: name("com.apple.system.Security"), to: Data([1]),
                                      on: item, policy: .alwaysSet)
        } == .ENOTSUP)
        #expect(driver.xattrCalls.isEmpty)
    }
}
