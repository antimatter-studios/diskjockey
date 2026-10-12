import Foundation
import FSKit
import Testing
@testable import DiskJockeyXFSCore
import DiskJockeyLibrary

private final class PolicyDriver: XfsMountedVolumeDriver {
    var isWritable = true
    func volumeInfo() -> ReadOnlyVolumeInfo? { nil }
    func stat(_ path: VolumePath) -> ReadOnlyFileAttributes? { nil }
    func walkDirectory(_ path: VolumePath,
                       _ visit: (ReadOnlyDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk { .finished }
    func read(_ path: VolumePath, at offset: UInt64,
              into buffer: UnsafeMutableRawBufferPointer) -> Int64 { -1 }
    func readlink(_ path: VolumePath, _ buffer: UnsafeMutablePointer<CChar>, _ size: Int) -> Int32 { -1 }
    func write(_ path: VolumePath, at offset: UInt64,
               from buffer: UnsafeRawBufferPointer) -> Int64 { -1 }
    func truncate(_ path: VolumePath, to size: UInt64, modified: timespec?) -> Int32 { -1 }
    func flush() -> Int32 { -1 }
    func create(_ path: VolumePath, mode: UInt16) -> UInt64 { 0 }
    func mkdir(_ path: VolumePath, mode: UInt16) -> UInt64 { 0 }
    func unlink(_ path: VolumePath) -> Int32 { -1 }
    func rmdir(_ path: VolumePath) -> Int32 { -1 }
    func link(_ source: VolumePath, to destination: VolumePath) -> Int32 { -1 }
    func rename(_ source: VolumePath, to destination: VolumePath, replace: Bool) -> Int32 { -1 }
    func setAttributes(_ path: VolumePath, mode: UInt32?, uid: UInt32?, gid: UInt32?,
                       accessed: timespec?, modified: timespec?) -> Int32 { -1 }
    func lastErrno() -> Int32 { EIO }
    func unmount() { isWritable = false }
}

private func policyVolume(_ driver: PolicyDriver, access: XfsMountAccess = .readOnly) -> XfsVolume {
    XfsVolume(volumeID: FSVolume.Identifier(), volumeName: FSFileName(string: "policy"),
              driver: driver, contextPtr: nil, bsdName: "policy-test",
              stats: IOStatsCollector(label: "policy-test", emit: { _ in }), mountAccess: access)
}

/// The rule: an XFS volume mounts read-write whenever the device can be
/// written and the mounted driver reports it can write. It is read-only
/// only when the device is read-only, the driver cannot write, or the
/// mount asks for `ro` or FSKit's `--rdonly`. A driver that cannot write
/// still gives a read-only mount, whose mutations answer EROFS.
@Suite("XFS writable mount policy")
struct XfsMountPolicyTests {
    @Test(arguments: [["ro"], ["--rdonly"], ["ro", "rw"], ["rw", "ro"], ["rw,ro"], ["ro,rw"],
                      ["rw", "--rdonly"], ["--rdonly", "rw"], ["partition_offset=4096,ro"]])
    func readOnlyOptionsVetoWrites(_ options: [String]) {
        #expect(XfsMountPolicy(options: options) == .readOnly)
    }

    /// No option is needed to ask for writes: read-write is the default.
    @Test(arguments: [[], ["rw"], ["-o", "rw"], ["partition_offset=4096"], ["rw=1"], ["-f"],
                      ["partition_offset=4096,rw"], ["rw", "rw"]])
    func everyOtherOptionSetAsksForWrites(_ options: [String]) {
        #expect(XfsMountPolicy(options: options) == .readWrite)
    }

    @Test(arguments: [false, true])
    func readOnlyPolicyNeverAuthorizesWrites(_ hardware: Bool) throws {
        let access = try XfsMountPolicy.readOnly.authorize(
            deviceIsWritable: hardware, mountedDriver: .success(true))
        #expect(!access.allowsWrites)
        #expect(policyVolume(PolicyDriver(), access: access)
            .supportedVolumeCapabilities.doesNotSupportSettingFilePermissions)
    }

    @Test func readOnlyDriverStillMountsSafely() throws {
        let access = try XfsMountPolicy.readOnly.authorize(
            deviceIsWritable: false, mountedDriver: .success(false))
        #expect(!access.allowsWrites)
    }

    /// Read-only hardware is a read-only mount, not a refused one.
    @Test(arguments: [[String](), ["rw"]])
    func readOnlyHardwareMountsReadOnly(_ options: [String]) throws {
        let access = try XfsMountPolicy(options: options).authorize(
            deviceIsWritable: false, mountedDriver: .success(true))
        #expect(!access.allowsWrites)
        let volume = policyVolume(PolicyDriver(), access: access)
        #expect(throws: POSIXError(.EROFS)) { try volume.requireWritableMount() }
    }

    /// Fail closed: a driver that cannot write still mounts, read-only,
    /// and every mutation answers EROFS.
    @Test(arguments: [[String](), ["rw"]])
    func aDriverThatCannotWriteMountsReadOnly(_ options: [String]) throws {
        let access = try XfsMountPolicy(options: options).authorize(
            deviceIsWritable: true, mountedDriver: .success(false))
        #expect(!access.allowsWrites)
        let volume = policyVolume(PolicyDriver(), access: access)
        #expect(!volume.allowsWrites)
        #expect(throws: POSIXError(.EROFS)) { try volume.requireWritableMount() }
        #expect(volume.supportedVolumeCapabilities.doesNotSupportSettingFilePermissions)
    }

    @Test(arguments: [XfsMountPolicy.readOnly, .readWrite])
    func unknownFeatureRefusalIsNotDowngraded(_ policy: XfsMountPolicy) {
        #expect(throws: POSIXError(.ENOTSUP)) {
            try policy.authorize(deviceIsWritable: true,
                                 mountedDriver: .failure(POSIXError(.ENOTSUP)))
        }
    }

    @Test(arguments: [XfsMountPolicy.readOnly, .readWrite])
    func dirtyOrUnsafeMountRefusalIsNotDowngraded(_ policy: XfsMountPolicy) {
        #expect(throws: POSIXError(.EIO)) {
            try policy.authorize(deviceIsWritable: true,
                                 mountedDriver: .failure(POSIXError(.EIO)))
        }
    }

    /// Writable hardware and a writable driver are enough: no `rw`.
    @Test func writableHardwareAndDriverAuthorizeWritesByDefault() throws {
        let access = try XfsMountPolicy(options: []).authorize(
            deviceIsWritable: true, mountedDriver: .success(true))
        let volume = policyVolume(PolicyDriver(), access: access)
        #expect(volume.allowsWrites)
        try volume.requireWritableMount()
        let capabilities = volume.supportedVolumeCapabilities
        #expect(!capabilities.doesNotSupportSettingFilePermissions)
        // Mount permission cannot invent operation/journal support.
        #expect(!capabilities.supportsHardLinks)
        #expect(!capabilities.supportsActiveJournal)
    }

    /// A read-only volume stays read-only whatever options arrive later,
    /// and asking for `rw` then does not fail the mount.
    @Test(arguments: [[String](), ["rw"]])
    func laterOptionsNeverUpgradeAReadOnlyVolume(_ options: [String]) throws {
        let volume = policyVolume(PolicyDriver())
        try volume.applyMountOptions(options)
        #expect(!volume.allowsWrites)
        #expect(throws: POSIXError(.EROFS)) { try volume.requireWritableMount() }
    }

    @Test(arguments: [["ro"], ["--rdonly"], ["ro,rw"]])
    func laterReadOnlyOptionsRevokeWrites(_ options: [String]) throws {
        let access = try XfsMountPolicy.readWrite.authorize(
            deviceIsWritable: true, mountedDriver: .success(true))
        let volume = policyVolume(PolicyDriver(), access: access)
        try volume.applyMountOptions(options)
        #expect(!volume.allowsWrites)
        #expect(volume.supportedVolumeCapabilities.doesNotSupportSettingFilePermissions)
        try volume.applyMountOptions(["rw"])
        #expect(!volume.allowsWrites, "a revoked volume was upgraded again")
    }

    @Test func laterDefaultOptionsKeepALoadedWritableVolumeWritable() throws {
        let access = try XfsMountPolicy.readWrite.authorize(
            deviceIsWritable: true, mountedDriver: .success(true))
        let volume = policyVolume(PolicyDriver(), access: access)
        try volume.applyMountOptions([])
        try volume.applyMountOptions(["rw"])
        #expect(volume.allowsWrites)
    }

    /// Load asks the driver for a writable mount only when one could be
    /// granted: a read-only request or read-only hardware never reaches
    /// the writable mount at all.
    @Test func onlyAWritableRequestOnWritableHardwareAsksForAWritableMount() {
        #expect(XfsMountPolicy.readWrite.requestsWritableMount(deviceIsWritable: true))
        #expect(!XfsMountPolicy.readWrite.requestsWritableMount(deviceIsWritable: false))
        #expect(!XfsMountPolicy.readOnly.requestsWritableMount(deviceIsWritable: true))
        #expect(!XfsMountPolicy.readOnly.requestsWritableMount(deviceIsWritable: false))
    }

    @Test func staleDriverApprovalCannotExposeWrites() throws {
        let access = try XfsMountPolicy.readWrite.authorize(
            deviceIsWritable: true, mountedDriver: .success(true))
        let driver = PolicyDriver()
        driver.isWritable = false
        let volume = policyVolume(driver, access: access)
        #expect(!volume.allowsWrites)
        #expect(throws: POSIXError(.EROFS)) { try volume.requireWritableMount() }
    }

    @Test func unmountedVolumeLosesMutationCapabilities() async throws {
        let access = try XfsMountPolicy.readWrite.authorize(
            deviceIsWritable: true, mountedDriver: .success(true))
        let volume = policyVolume(PolicyDriver(), access: access)
        await volume.unmount()
        #expect(!volume.allowsWrites)
        #expect(volume.supportedVolumeCapabilities.doesNotSupportSettingFilePermissions)
        #expect(throws: POSIXError(.EROFS)) { try volume.requireWritableMount() }
    }

    /// Every namespace change is mapped (XfsNamespaceTests holds them), so
    /// over a driver that refuses each call the volume answers the driver's
    /// errno, never success; a symlink, which rust-fs-xfs makes none of,
    /// stays ENOTSUP.
    @Test func approvedMountAnswersARefusingDriversErrnoNotSuccess() async throws {
        let access = try XfsMountPolicy.readWrite.authorize(
            deviceIsWritable: true, mountedDriver: .success(true))
        let volume = policyVolume(PolicyDriver(), access: access)
        let item = volume.item(forInode: 1, path: .root, parentInode: nil)
        let name = FSFileName(string: "child")
        let attributes = FSItem.SetAttributesRequest()
        await #expect(throws: POSIXError(.EIO)) {
            try await volume.createItem(named: name, type: .file, inDirectory: item, attributes: attributes)
        }
        await #expect(throws: POSIXError(.ENOTSUP)) {
            try await volume.createSymbolicLink(named: name, inDirectory: item,
                                               attributes: attributes, linkContents: name)
        }
        await #expect(throws: POSIXError(.EIO)) { try await volume.createLink(to: item, named: name, inDirectory: item) }
        await #expect(throws: POSIXError(.EIO)) { try await volume.removeItem(item, named: name, fromDirectory: item) }
        await #expect(throws: POSIXError(.EIO)) {
            try await volume.renameItem(item, inDirectory: item, named: name, to: name,
                                        inDirectory: item, overItem: nil)
        }
    }
}
