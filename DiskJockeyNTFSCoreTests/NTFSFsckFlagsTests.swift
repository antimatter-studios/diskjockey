import Testing
@testable import DiskJockeyNTFSCore

/// Which fsck clears the dirty flag (diskjockey#367): only the one a person
/// asked for. The flag asks Windows for a whole-volume check this driver
/// does not make (rust-fs-ntfs#519).
@Suite("NTFS fsck flags")
struct NTFSFsckFlagsTests {
    @Test func verifyClearsTheDirtyFlag() {
        #expect(NTFSFsckFlags.userVerify & NTFSFsckFlags.clearDirty != 0)
    }

    @Test func aRemountsOwnCheckLeavesTheDirtyFlag() {
        #expect(NTFSFsckFlags.automaticRemount & NTFSFsckFlags.clearDirty == 0)
    }

    /// The bit fs_ntfs.h defines as FS_NTFS_FSCK_CLEAR_DIRTY.
    @Test func theClearDirtyBitIsTheHeadersOne() {
        #expect(NTFSFsckFlags.clearDirty == 0x01)
    }
}
