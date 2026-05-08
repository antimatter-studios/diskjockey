//
//  EXT4AttributeMaskTests.swift — regression tests for the FSKit attribute
//  mask returned from EXT4Volume.attributes(_:of:) and attributes(from:).
//
//  WHY THIS FILE EXISTS
//  --------------------
//  FSKit's `FSVolumeConnector.getStandardItemAttributesForItem` validates
//  the bit set of the FSItem.Attributes object the volume returns. When
//  the reported mask is missing any bit from FSKit's "standard" set, the
//  connector logs:
//
//      attributes mask is 0x4000000000001ddf, expected 0x4000000000003fe7
//      Reported attributes are incomplete
//      ...reply:error:2
//
//  …and the kernel turns the call into ENOENT (errno 2). Userspace tools
//  see the freshly-saved file as "vanished" — touch/vim work because they
//  use a different attribute-fetch path, but GUI editors that do an
//  atomic save (write-temp + rename + restat) consistently fail.
//
//  The unit-test bundle can't import FSKit (lives behind the
//  ExtensionKit extension boundary) or construct an `FSItem.Attributes`
//  directly. So we mirror the bit layout from
//      <FSKit/FSItem.h> — `FSItemAttribute` (NS_OPTIONS, NSInteger)
//  and the volume's attribute-population logic, then verify the mirrored
//  output covers the standard-set mask.
//
//  IF YOU CHANGE EXT4Volume.attributes(_:of:) OR attributes(from:),
//  UPDATE `FSKitAttributesMirror.populate(...)` BELOW to match. The
//  pattern is the same one used by EXT4VolumeTests / NTFSVolumeTests —
//  protocol mirrors with hand-kept fidelity.
//

import Foundation
import Testing

// MARK: - FSKit bit layout (mirrored from FSItem.h)

/// Bit positions of `FSItemAttribute` in the macOS 26 SDK
/// (`<FSKit/FSItem.h>`). NSInteger option-set, so each bit is `1 << N`.
/// Keep this aligned with the SDK header — the runtime expected mask
/// comes from these positions.
private struct FSAttribute: OptionSet, Hashable {
    let rawValue: UInt64
    init(rawValue: UInt64) { self.rawValue = rawValue }

    static let type                     = FSAttribute(rawValue: 1 <<  0)
    static let mode                     = FSAttribute(rawValue: 1 <<  1)
    static let linkCount                = FSAttribute(rawValue: 1 <<  2)
    static let uid                      = FSAttribute(rawValue: 1 <<  3)
    static let gid                      = FSAttribute(rawValue: 1 <<  4)
    static let flags                    = FSAttribute(rawValue: 1 <<  5)
    static let size                     = FSAttribute(rawValue: 1 <<  6)
    static let allocSize                = FSAttribute(rawValue: 1 <<  7)
    static let fileID                   = FSAttribute(rawValue: 1 <<  8)
    static let parentID                 = FSAttribute(rawValue: 1 <<  9)
    static let accessTime               = FSAttribute(rawValue: 1 << 10)
    static let modifyTime               = FSAttribute(rawValue: 1 << 11)
    static let changeTime               = FSAttribute(rawValue: 1 << 12)
    static let birthTime                = FSAttribute(rawValue: 1 << 13)
    static let backupTime               = FSAttribute(rawValue: 1 << 14)
    static let addedTime                = FSAttribute(rawValue: 1 << 15)
    static let supportsLimitedXAttrs    = FSAttribute(rawValue: 1 << 16)
    static let inhibitKernelOffloadedIO = FSAttribute(rawValue: 1 << 17)

    /// The mask FSKit's `getStandardItemAttributesForItem` requires every
    /// volume to populate. Sourced verbatim from a runtime log line —
    /// hex was `0x3fe7` after stripping FSKit's high sequence-number
    /// bits — and verified against the FSItem.h bit positions above.
    /// Any FSItem.Attributes reply missing a bit from this mask makes
    /// the connector reply with errno 2 (ENOENT) to userspace, which
    /// looks to the user like the file vanished.
    static let standard: FSAttribute = [
        .type, .mode, .linkCount, .flags,
        .size, .allocSize, .fileID, .parentID,
        .accessTime, .modifyTime, .changeTime, .birthTime,
    ]
}

// MARK: - Fixture: a backend stat result

/// Mirror of `BackendFileAttributes` (lives inside the EXT4 extension
/// target — not visible here). Carries everything the EXT4 driver hands
/// the volume layer when it does a `stat(path:)`.
private struct FixtureStat {
    var fileID: UInt64
    var fileType: FixtureFileType
    var mode: UInt16
    var uid: UInt32
    var gid: UInt32
    var size: UInt64
    var linkCount: UInt16
    var atime: UInt32
    var mtime: UInt32
    var ctime: UInt32
    var crtime: UInt32
}

private enum FixtureFileType { case file, directory, symlink }

private enum AttributeMaskFixtures {
    /// Representative regular file: every timestamp populated (including
    /// crtime — ext4 stores i_crtime which is the *birth* time on disk),
    /// non-zero size, mode, uid/gid. Sits in a non-root directory so
    /// parentID can't be papered over with FSItemIDParentOfRoot.
    static let regularFileInSubdir = FixtureStat(
        fileID: 12345,
        fileType: .file,
        mode: 0o644,
        uid: 501,
        gid: 20,
        size: 4096,
        linkCount: 1,
        atime: 1_700_000_000,
        mtime: 1_700_000_100,
        ctime: 1_700_000_100,
        crtime: 1_699_000_000
    )

    /// Inode that the regular file's parent directory holds. Used to
    /// drive parentID — a non-root parent rules out the
    /// "FSItemIDParentOfRoot keeps the test happy by accident" trap.
    static let regularFileParentInode: UInt32 = 67890

    /// Empty directory created via `mkdir`, exactly the case the user
    /// reported as "vanishing one second later" in Finder. Same shape as
    /// regularFileInSubdir but type=.directory and zero bytes.
    static let emptyDirectoryInSubdir = FixtureStat(
        fileID: 24680,
        fileType: .directory,
        mode: 0o755,
        uid: 501,
        gid: 20,
        size: 0,
        linkCount: 2,
        atime: 1_700_000_000,
        mtime: 1_700_000_000,
        ctime: 1_700_000_000,
        crtime: 1_700_000_000
    )

    static let emptyDirectoryParentInode: UInt32 = 67890
}

// MARK: - Mirror of the volume's attribute-population path

/// Records which FSItem.Attribute bits an attribute reply would set.
/// Drop-in stand-in for `FSItem.Attributes` — every property assigned
/// here flips its bit in `validBits`. The bit layout matches FSKit's
/// `FSItemAttribute`.
private struct FSKitAttributesMirror {
    private(set) var validBits: FSAttribute = []

    // The values are kept so individual fields can be asserted
    // (e.g. crtime was placed into birthTime, not addedTime).
    var type: FixtureFileType?       { didSet { validBits.insert(.type) } }
    var mode: UInt32?                { didSet { validBits.insert(.mode) } }
    var uid: UInt32?                 { didSet { validBits.insert(.uid) } }
    var gid: UInt32?                 { didSet { validBits.insert(.gid) } }
    var flags: UInt32?               { didSet { validBits.insert(.flags) } }
    var size: UInt64?                { didSet { validBits.insert(.size) } }
    var allocSize: UInt64?           { didSet { validBits.insert(.allocSize) } }
    var linkCount: UInt32?           { didSet { validBits.insert(.linkCount) } }
    var fileID: UInt64?              { didSet { validBits.insert(.fileID) } }
    var parentID: UInt64?            { didSet { validBits.insert(.parentID) } }
    var accessTimeSec: UInt32?       { didSet { validBits.insert(.accessTime) } }
    var modifyTimeSec: UInt32?       { didSet { validBits.insert(.modifyTime) } }
    var changeTimeSec: UInt32?       { didSet { validBits.insert(.changeTime) } }
    var birthTimeSec: UInt32?        { didSet { validBits.insert(.birthTime) } }
    var addedTimeSec: UInt32?        { didSet { validBits.insert(.addedTime) } }
    var backupTimeSec: UInt32?       { didSet { validBits.insert(.backupTime) } }
}

/// Mirrors the body of `EXT4Volume.attributes(from:parentInode:)`.
///
/// IMPORTANT: this driver MUST stay in lock-step with the production
/// implementation in `DiskJockeyEXT4/EXT4Volume.swift`. When you change
/// the volume's attribute-population, update the assignments here so
/// the regression coverage stays meaningful.
///
/// `parentInode` is `nil` only for the root directory — its parent is
/// the FSKit-defined sentinel `FSItemIDParentOfRoot` (= 1).
private func driveBuildAttributes(
    from stat: FixtureStat,
    parentInode: UInt32?
) -> FSKitAttributesMirror {
    var attrs = FSKitAttributesMirror()

    // ----- begin mirror of EXT4Volume.swift attributes(from:parentInode:) -----
    attrs.type      = stat.fileType
    attrs.mode      = UInt32(stat.mode & 0o7777)
    attrs.uid       = stat.uid
    attrs.gid       = stat.gid
    // ext4 inode flags aren't surfaced by the FFI yet; 0 is correct for
    // the common case and marks bit 5 valid so FSKit accepts the reply.
    attrs.flags     = 0
    attrs.size      = stat.size
    attrs.linkCount = UInt32(stat.linkCount)
    attrs.allocSize = stat.size
    attrs.accessTimeSec = stat.atime
    attrs.modifyTimeSec = stat.mtime
    attrs.changeTimeSec = stat.ctime
    // ext4 i_crtime IS the on-disk birth time. It must land on
    // birthTime (bit 13) — addedTime (bit 15) is an HFS+/APFS concept
    // and isn't in FSKit's standard mask.
    attrs.birthTimeSec = stat.crtime
    attrs.fileID = stat.fileID
    // Root's parent is the FSKit sentinel FSItemIDParentOfRoot (= 1).
    attrs.parentID = UInt64(parentInode ?? 1)
    // -----  end mirror of EXT4Volume.swift attributes(from:parentInode:)  -----

    return attrs
}

// MARK: - Tests

struct EXT4AttributeMaskTests {

    /// Top-level regression: the produced mask must cover every bit
    /// FSKit's standard set demands. This is the single assertion that
    /// would have caught the original bug — a missing bit makes
    /// `getStandardItemAttributesForItem` reply errno 2 to userspace.
    @Test func standardSetIsFullyCovered() throws {
        let attrs = driveBuildAttributes(
            from: AttributeMaskFixtures.regularFileInSubdir,
            parentInode: AttributeMaskFixtures.regularFileParentInode
        )
        let missing = FSAttribute.standard.subtracting(attrs.validBits)
        #expect(missing.isEmpty,
                "Missing required FSKit attribute bits: 0x\(String(missing.rawValue, radix: 16))")
    }

    /// Same assertion for an empty directory (the "create folder, it
    /// vanishes a second later" symptom). Different fixture so the test
    /// covers the directory branch — same contract.
    @Test func standardSetCoveredForEmptyDirectory() throws {
        let attrs = driveBuildAttributes(
            from: AttributeMaskFixtures.emptyDirectoryInSubdir,
            parentInode: AttributeMaskFixtures.emptyDirectoryParentInode
        )
        let missing = FSAttribute.standard.subtracting(attrs.validBits)
        #expect(missing.isEmpty,
                "Missing required FSKit attribute bits for directory: 0x\(String(missing.rawValue, radix: 16))")
    }

    /// Pinpoint each missing bit individually. Lets a developer fixing
    /// the bug see all three failures up-front rather than fixing one
    /// and re-running.
    @Test func flagsBitMustBeSet() throws {
        let attrs = driveBuildAttributes(
            from: AttributeMaskFixtures.regularFileInSubdir,
            parentInode: AttributeMaskFixtures.regularFileParentInode
        )
        #expect(attrs.validBits.contains(.flags),
                "FSItem.Attributes.flags must be assigned (e.g. `attrs.flags = 0`)")
    }

    @Test func parentIDBitMustBeSet() throws {
        let attrs = driveBuildAttributes(
            from: AttributeMaskFixtures.regularFileInSubdir,
            parentInode: AttributeMaskFixtures.regularFileParentInode
        )
        #expect(attrs.validBits.contains(.parentID),
                "FSItem.Attributes.parentID must be assigned — thread the parent inode through EXT4Item")
    }

    @Test func birthTimeBitMustBeSet() throws {
        let attrs = driveBuildAttributes(
            from: AttributeMaskFixtures.regularFileInSubdir,
            parentInode: AttributeMaskFixtures.regularFileParentInode
        )
        #expect(attrs.validBits.contains(.birthTime),
                "FSItem.Attributes.birthTime must be assigned from stat.crtime (ext4 i_crtime is the birth time)")
    }

    /// Crtime → birthTime (bit 13), not addedTime (bit 15). On ext4
    /// `i_crtime` is the on-disk birth/creation time. addedTime is an
    /// HFS+/APFS concept: when this dirent was added to its current
    /// parent. Setting only addedTime leaves the standard-set's
    /// birthTime bit unpopulated, which is exactly the regression we hit.
    @Test func crtimeMapsToBirthTimeNotAddedTime() throws {
        let attrs = driveBuildAttributes(
            from: AttributeMaskFixtures.regularFileInSubdir,
            parentInode: AttributeMaskFixtures.regularFileParentInode
        )
        #expect(attrs.birthTimeSec == AttributeMaskFixtures.regularFileInSubdir.crtime,
                "stat.crtime must be assigned to FSItem.Attributes.birthTime")
        // addedTime is not in FSKit's standard set, so populating it is
        // never harmful — but if you populate ONLY addedTime you will
        // satisfy bit 15 and still miss bit 13. Pin that explicitly.
        if attrs.addedTimeSec != nil {
            #expect(attrs.birthTimeSec != nil,
                    "If addedTime is populated from crtime, birthTime MUST also be populated — otherwise bit 13 stays clear")
        }
    }

    /// Pin the mirror's exact mask to guard against silent regressions.
    /// The original buggy code produced `0x9ddf` (or `0x1ddf` when
    /// `crtime == 0`). The fixed mirror should produce a mask that is
    /// a strict superset of FSKit's standard set `0x3fe7` and includes
    /// uid/gid (bits 3, 4) which we volunteer beyond the standard set
    /// because FSKit consumers (Finder Get Info, ls -l) expect them.
    @Test func mirrorProducesPostFixMask() throws {
        let attrs = driveBuildAttributes(
            from: AttributeMaskFixtures.regularFileInSubdir,
            parentInode: AttributeMaskFixtures.regularFileParentInode
        )
        // Standard set (0x3fe7) ∪ uid (0x08) ∪ gid (0x10) = 0x3fff.
        let expected: UInt64 = 0x3fff
        #expect(attrs.validBits.rawValue == expected,
                "Mirror produced 0x\(String(attrs.validBits.rawValue, radix: 16)); expected 0x\(String(expected, radix: 16))")
        // Sanity: must not regress into the originally-observed failing
        // mask shapes the bug report captured at runtime.
        #expect(attrs.validBits.rawValue != 0x1ddf)
        #expect(attrs.validBits.rawValue != 0x9ddf)
    }
}
