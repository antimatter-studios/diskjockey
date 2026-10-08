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
    func lastErrno() -> Int32 { EIO }
    func unmount() { isWritable = false }
}

private func policyVolume(_ driver: PolicyDriver, access: XfsMountAccess = .readOnly) -> XfsVolume {
    XfsVolume(volumeID: FSVolume.Identifier(), volumeName: FSFileName(string: "policy"),
              driver: driver, contextPtr: nil, bsdName: "policy-test",
              stats: IOStatsCollector(label: "policy-test", emit: { _ in }), mountAccess: access)
}

@Suite("XFS writable mount policy")
struct XfsMountPolicyTests {
    @Test(arguments: [[], ["ro"], ["--rdonly"], ["partition_offset=4096"], ["rw=1"],
                      ["-f"], ["ro", "rw"], ["rw", "ro"], ["rw,ro"], ["ro,rw"],
                      ["rw", "--rdonly"], ["--rdonly", "rw"]])
    func defaultAndReadOnlyOptionsVetoWrites(_ options: [String]) {
        #expect(XfsMountPolicy(options: options) == .readOnly)
    }

    @Test(arguments: [["rw"], ["-o", "rw"], ["partition_offset=4096,rw"], ["rw", "rw"]])
    func explicitWritableOptions(_ options: [String]) {
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

    @Test func readOnlyHardwareRefusesExplicitWrites() {
        #expect(throws: POSIXError(.EROFS)) {
            try XfsMountPolicy.readWrite.authorize(
                deviceIsWritable: false, mountedDriver: .success(true))
        }
    }

    @Test func mountedDriverCanRefuseWritablePolicy() {
        #expect(throws: POSIXError(.EROFS)) {
            try XfsMountPolicy.readWrite.authorize(
                deviceIsWritable: true, mountedDriver: .success(false))
        }
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

    @Test func onlyExplicitHardwareAndMountedDriverApprovalExposePermissionWrites() throws {
        let access = try XfsMountPolicy.readWrite.authorize(
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

    @Test func writableDriverAloneDoesNotEnableMutations() {
        let volume = policyVolume(PolicyDriver())
        #expect(!volume.allowsWrites)
        #expect(throws: POSIXError(.EROFS)) { try volume.requireWritableMount() }
        #expect(throws: POSIXError(.EROFS)) { try volume.applyMountOptions(["rw"]) }
    }

    @Test(arguments: [["ro"], ["--rdonly"], ["ro,rw"]])
    func laterReadOnlyOptionsRevokeWrites(_ options: [String]) throws {
        let access = try XfsMountPolicy.readWrite.authorize(
            deviceIsWritable: true, mountedDriver: .success(true))
        let volume = policyVolume(PolicyDriver(), access: access)
        try volume.applyMountOptions(options)
        #expect(!volume.allowsWrites)
        #expect(volume.supportedVolumeCapabilities.doesNotSupportSettingFilePermissions)
        #expect(throws: POSIXError(.EROFS)) { try volume.applyMountOptions(["rw"]) }
    }

    @Test func laterDefaultOptionsPreserveExplicitLoadPolicy() throws {
        let access = try XfsMountPolicy.readWrite.authorize(
            deviceIsWritable: true, mountedDriver: .success(true))
        let volume = policyVolume(PolicyDriver(), access: access)
        try volume.applyMountOptions([])
        try volume.applyMountOptions(["rw"])
        #expect(volume.allowsWrites)
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

    /// Writes and size changes are mapped; XfsWriteTests holds them.
    @Test func approvedMountDoesNotPretendUnmappedOperationsSucceeded() async throws {
        let access = try XfsMountPolicy.readWrite.authorize(
            deviceIsWritable: true, mountedDriver: .success(true))
        let volume = policyVolume(PolicyDriver(), access: access)
        let item = volume.item(forInode: 1, path: .root, parentInode: nil)
        let name = FSFileName(string: "child")
        let attributes = FSItem.SetAttributesRequest()
        await #expect(throws: POSIXError(.ENOTSUP)) {
            try await volume.createItem(named: name, type: .file, inDirectory: item, attributes: attributes)
        }
        await #expect(throws: POSIXError(.ENOTSUP)) {
            try await volume.createSymbolicLink(named: name, inDirectory: item,
                                               attributes: attributes, linkContents: name)
        }
        await #expect(throws: POSIXError(.ENOTSUP)) { try await volume.createLink(to: item, named: name, inDirectory: item) }
        await #expect(throws: POSIXError(.ENOTSUP)) { try await volume.removeItem(item, named: name, fromDirectory: item) }
        await #expect(throws: POSIXError(.ENOTSUP)) {
            try await volume.renameItem(item, inDirectory: item, named: name, to: name,
                                        inDirectory: item, overItem: nil)
        }
    }
}
