import Testing
@testable import DiskJockeyNTFSCore

/// Records the mount calls a remount makes, and answers each from a table.
private final class RecordingRemount: NTFSRemounting {
    enum Call: Hashable {
        case callbacks(writable: Bool)
        case deviceChain(writable: Bool)
    }

    let remountsThroughDeviceChain: Bool
    /// Which mounts the driver refuses, by the call that asks for them.
    var refused: Set<Call> = []
    private(set) var calls: [Call] = []

    init(throughDeviceChain: Bool) {
        remountsThroughDeviceChain = throughDeviceChain
    }

    func mountThroughCallbacks(writable: Bool) -> Bool {
        answer(.callbacks(writable: writable))
    }

    func mountThroughDeviceChain(writable: Bool) -> Bool {
        answer(.deviceChain(writable: writable))
    }

    private func answer(_ call: Call) -> Bool {
        calls.append(call)
        return !refused.contains(call)
    }
}

/// The remount after a check goes through the resource the volume was
/// mounted from (diskjockey#369). For a disk-image container or a partition
/// slice the raw device is not the NTFS volume: mounting it reads the
/// container's own bytes, or the disk's first sector rather than the
/// partition's, and the volume is left with no handle.
@Suite("NTFS remount after a check")
struct NTFSRemountTests {

    // MARK: a container or partition volume

    @Test func aWritableContainerVolumeIsMountedAgainThroughTheDeviceChain() {
        let driver = RecordingRemount(throughDeviceChain: true)
        #expect(NTFSRemount.afterCheck(driver, writable: true) == .readWrite)
        #expect(driver.calls == [.deviceChain(writable: true)])
    }

    @Test func aContainerVolumeTheDriverWillNotWriteIsMountedReadOnlyThroughTheDeviceChain() {
        let driver = RecordingRemount(throughDeviceChain: true)
        driver.refused = [.deviceChain(writable: true)]
        #expect(NTFSRemount.afterCheck(driver, writable: true) == .readOnly)
        #expect(driver.calls == [.deviceChain(writable: true), .deviceChain(writable: false)])
    }

    @Test func aReadOnlyContainerVolumeIsMountedReadOnlyThroughTheDeviceChain() {
        let driver = RecordingRemount(throughDeviceChain: true)
        #expect(NTFSRemount.afterCheck(driver, writable: false) == .readOnly)
        #expect(driver.calls == [.deviceChain(writable: false)])
    }

    /// Neither mount works: the raw device is never tried in their place.
    @Test func aContainerVolumeThatWillNotMountIsNeverMountedFromTheRawDevice() {
        let driver = RecordingRemount(throughDeviceChain: true)
        driver.refused = [.deviceChain(writable: true), .deviceChain(writable: false)]
        #expect(NTFSRemount.afterCheck(driver, writable: true) == nil)
        #expect(!driver.calls.contains(.callbacks(writable: true)))
        #expect(!driver.calls.contains(.callbacks(writable: false)))
    }

    // MARK: a whole-device volume

    @Test func aWritableWholeDeviceVolumeIsMountedAgainOverTheCallbacks() {
        let driver = RecordingRemount(throughDeviceChain: false)
        #expect(NTFSRemount.afterCheck(driver, writable: true) == .readWrite)
        #expect(driver.calls == [.callbacks(writable: true)])
    }

    @Test func aWholeDeviceVolumeTheDriverWillNotWriteIsMountedReadOnly() {
        let driver = RecordingRemount(throughDeviceChain: false)
        driver.refused = [.callbacks(writable: true)]
        #expect(NTFSRemount.afterCheck(driver, writable: true) == .readOnly)
        #expect(driver.calls == [.callbacks(writable: true), .callbacks(writable: false)])
    }

    /// A volume loaded read-only is not handed a write callback by a check.
    @Test func aReadOnlyWholeDeviceVolumeIsMountedReadOnly() {
        let driver = RecordingRemount(throughDeviceChain: false)
        #expect(NTFSRemount.afterCheck(driver, writable: false) == .readOnly)
        #expect(driver.calls == [.callbacks(writable: false)])
    }
}
