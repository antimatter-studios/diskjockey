//
//  ReadOnlyVolumeSupport.swift — the parts of a read-only FSKit volume
//  that are the same for every filesystem, in the one place a test can
//  reach them.
//
//  WHY THIS EXISTS
//
//  DiskJockey has four read-only volumes — XFS, Btrfs, EROFS and
//  SquashFS. Normalising the filesystem's name away and diffing them
//  pairwise gives 88% to 98% identical lines; XFS and Btrfs differ in
//  six lines out of 370. They are one class written four times, and the
//  copies have already drifted: the XFS volume shipped with
//  `supportsJournal = false`, inherited from the EROFS volume it was
//  copied from, and XFS has a journal.
//
//  None of that was catchable by a test. The volume classes live in the
//  extension appex targets, and a test bundle that links the app cannot
//  see them — `cannot find 'XfsVolume' in scope`. So every volume test
//  in this project mirrors the volume's wiring against a mock instead of
//  exercising the volume, and a mirror asserts only what the mirror was
//  written to say.
//
//  This module is the fix: the decisions that differ between filesystems
//  live here as data and plain functions, in a target the tests already
//  cover. What stays in each extension is the C ABI call and the
//  conversion into these types.
//
//  FSKit's own types are used directly rather than shadowed. That was
//  worth checking rather than assuming — the existing volume tests carry
//  a comment saying FSKit types "can't easily be constructed in a
//  unit-test bundle", which is not true: `FSItem.Attributes()` and
//  `FSStatFSResult(fileSystemTypeName:)` both build and run in
//  DiskJockeyLibraryTests.
//

import FSKit
import Foundation

// MARK: - What a driver reports

/// One file's metadata, as every read-only driver in this project
/// reports it.
///
/// A neutral struct rather than each crate's own `fs_<fs>_attr_t`,
/// because those are distinct C types that cannot be spelled in shared
/// code. Each extension converts its own into this.
public struct ReadOnlyFileAttributes: Equatable, Sendable {
    /// The filesystem's own identifier for the file. All four drivers
    /// use 64 bits — XFS inode numbers, Btrfs object IDs, EROFS NIDs and
    /// SquashFS inode numbers alike — so this is `UInt64` rather than
    /// being made generic for a variation that does not exist.
    public var inode: UInt64
    public var mode: UInt32
    public var uid: UInt32
    public var gid: UInt32
    public var size: UInt64
    public var linkCount: UInt32
    /// Seconds since the epoch. Most drivers report one timestamp, not
    /// four; see `fsAttributes(from:parentInode:)` for what that means.
    public var mtime: Int64
    public var fileType: ReadOnlyFileType
    /// The access, inode-change and creation times, in seconds, for a
    /// driver that reports them; nil stands in `mtime`. A writable volume
    /// needs them, or a time it was asked to set reads back as another.
    public var atime: Int64?
    public var ctime: Int64?
    public var birthtime: Int64?

    public init(inode: UInt64, mode: UInt32, uid: UInt32, gid: UInt32,
                size: UInt64, linkCount: UInt32, mtime: Int64,
                fileType: ReadOnlyFileType,
                atime: Int64? = nil, ctime: Int64? = nil, birthtime: Int64? = nil) {
        self.inode = inode
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.size = size
        self.linkCount = linkCount
        self.mtime = mtime
        self.fileType = fileType
        self.atime = atime
        self.ctime = ctime
        self.birthtime = birthtime
    }
}

/// The file types a read-only driver distinguishes.
public enum ReadOnlyFileType: Equatable, Sendable {
    case file
    case directory
    case symlink
    case other

    /// FSKit's equivalent.
    public var fsItemType: FSItem.ItemType {
        switch self {
        case .file: return .file
        case .directory: return .directory
        case .symlink: return .symlink
        case .other: return .file
        }
    }
}

// MARK: - What a driver reports about the volume

/// Capacity, as the driver measures it.
///
/// The two cases exist because the drivers genuinely disagree about the
/// unit, and flattening that difference is what produces a wrong number
/// on somebody's disk.
public enum ReadOnlyCapacity: Equatable, Sendable {
    /// XFS, EROFS and SquashFS: a block size and a count of blocks.
    case blocks(blockSize: UInt64, total: UInt64, free: UInt64)

    /// Btrfs: a byte figure, with the block size reported separately.
    ///
    /// Btrfs has no fixed block count to report — capacity and usage are
    /// byte quantities, and its sector size is what a block would mean.
    /// Converting here rather than in the volume keeps the division in
    /// one testable place.
    case bytes(sectorSize: UInt64, total: UInt64, used: UInt64)

    /// SquashFS: a compressed image, where used IS total.
    ///
    /// The image is exactly as large as its contents and cannot grow, so
    /// there is no capacity figure distinct from usage and no free space
    /// to report. Modelled as its own case rather than passed as
    /// `.bytes(total: used, used: used)` because that spelling reads as
    /// a coincidence rather than as the format's nature.
    case compressedImage(blockSize: UInt64, usedBytes: UInt64)
}

/// Everything a read-only volume needs in order to answer `statfs`.
public struct ReadOnlyVolumeInfo: Equatable, Sendable {
    public var capacity: ReadOnlyCapacity
    /// The unit the volume advertises for I/O. Usually the block size,
    /// but Btrfs reports its node size, which is larger.
    public var ioSize: UInt64
    /// Total inodes, where the filesystem has a fixed inode table.
    ///
    /// `nil` where it does not. Btrfs allocates inodes from the same
    /// pool as data, so there is no total to report and no free count
    /// either; inventing one from the byte figures would be a number a
    /// user could act on wrongly. `nil` becomes zero at the FSKit
    /// boundary, which is what the field means when it is unknown.
    public var totalInodes: UInt64?
    public var freeInodes: UInt64?

    public init(capacity: ReadOnlyCapacity, ioSize: UInt64,
                totalInodes: UInt64? = nil, freeInodes: UInt64? = nil) {
        self.capacity = capacity
        self.ioSize = ioSize
        self.totalInodes = totalInodes
        self.freeInodes = freeInodes
    }
}

// MARK: - Capabilities

/// The capability flags that differ between these four filesystems.
///
/// Only the ones that actually vary are parameters. The rest are fixed
/// below, because four copies of the same nine assignments is how the
/// XFS volume ended up claiming it had no journal.
public struct ReadOnlyVolumeCapabilities: Equatable, Sendable {
    public var hasJournal: Bool
    public var supportsSymbolicLinks: Bool
    public var isCaseSensitive: Bool
    /// SquashFS says false here and the others say true. Kept as a
    /// parameter rather than normalised, because the flag describes what
    /// the format's identifiers are, not a preference.
    public var supports64BitObjectIDs: Bool

    public init(hasJournal: Bool,
                supportsSymbolicLinks: Bool = true,
                isCaseSensitive: Bool = true,
                supports64BitObjectIDs: Bool = true) {
        self.hasJournal = hasJournal
        self.supportsSymbolicLinks = supportsSymbolicLinks
        self.isCaseSensitive = isCaseSensitive
        self.supports64BitObjectIDs = supports64BitObjectIDs
    }

    /// The FSKit object, with the invariant parts filled in.
    ///
    /// `supportsActiveJournal` stays false even when there is a journal:
    /// these drivers refuse a filesystem with a dirty log rather than
    /// replaying one, so the journal is never active from here.
    public var fsCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsPersistentObjectIDs = true
        caps.supportsSymbolicLinks = supportsSymbolicLinks
        caps.supportsHardLinks = false
        caps.supportsJournal = hasJournal
        caps.supportsActiveJournal = false
        caps.supportsSparseFiles = true
        caps.supports2TBFiles = true
        caps.supports64BitObjectIDs = supports64BitObjectIDs
        caps.caseFormat = isCaseSensitive ? .sensitive : .insensitive
        return caps
    }
}

// MARK: - The conversions

public enum ReadOnlyVolumeSupport {

    /// Join a directory path and a child name.
    ///
    /// Written out because `"/" + "/" + name` produces `//name`, and a
    /// path with a doubled separator is not equal to the one the cache
    /// is keyed by even though it resolves to the same file.
    public static func joinPath(_ parent: String, _ child: String) -> String {
        parent == "/" ? "/\(child)" : "\(parent)/\(child)"
    }

    /// Turn a driver's attributes into FSKit's.
    ///
    /// The four timestamps are all set from the one the drivers report.
    /// That is not laziness: none of these formats gives all four, and
    /// leaving the others unset makes Finder show the epoch. One honest
    /// value repeated is better than three wrong ones.
    public static func fsAttributes(from attr: ReadOnlyFileAttributes,
                                    parentInode: UInt64?) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.type = attr.fileType.fsItemType
        attrs.mode = attr.mode
        attrs.uid = attr.uid
        attrs.gid = attr.gid
        attrs.flags = 0
        attrs.size = attr.size
        // Read-only and never sparse-aware here, so the allocated size
        // is the size.
        attrs.allocSize = attr.size
        attrs.linkCount = attr.linkCount
        let ts = timespec(tv_sec: Int(attr.mtime), tv_nsec: 0)
        attrs.accessTime = ts
        attrs.modifyTime = ts
        attrs.changeTime = ts
        attrs.birthTime = ts
        if let id = FSItem.Identifier(rawValue: attr.inode) {
            attrs.fileID = id
        }
        // Root's parent is itself, which is what inode 1 means here.
        if let parentID = FSItem.Identifier(rawValue: parentInode ?? 1) {
            attrs.parentID = parentID
        }
        return attrs
    }

    /// Turn a driver's volume info into FSKit's `statfs` answer.
    ///
    /// The byte-to-block division lives here rather than in a volume so
    /// that the divide-by-zero guard exists once. A driver that has not
    /// finished mounting reports a zero sector size, and a zero divisor
    /// would trap.
    public static func statFS(_ info: ReadOnlyVolumeInfo,
                              fileSystemTypeName: String) -> FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: fileSystemTypeName)

        switch info.capacity {
        case let .blocks(blockSize, total, free):
            result.blockSize = Int(blockSize)
            result.totalBlocks = total
            result.freeBlocks = free

        case let .bytes(sectorSize, total, used):
            result.blockSize = Int(sectorSize)
            guard sectorSize > 0 else {
                result.totalBlocks = 0
                result.freeBlocks = 0
                break
            }
            let totalSectors = total / sectorSize
            let usedSectors = used / sectorSize
            result.totalBlocks = totalSectors
            // Saturating: a driver reporting more used than total is
            // corrupt, and an unsigned wrap would report an enormous
            // amount of free space on a full disk.
            result.freeBlocks = totalSectors >= usedSectors ? totalSectors - usedSectors : 0

        case let .compressedImage(blockSize, usedBytes):
            result.blockSize = Int(blockSize)
            guard blockSize > 0 else {
                result.totalBlocks = 0
                result.freeBlocks = 0
                break
            }
            // Used is total: the image is exactly as large as it needs
            // to be and cannot grow.
            result.totalBlocks = usedBytes / blockSize
            result.freeBlocks = 0
        }

        // Zero for every one of these volumes, whatever is free. They are
        // read-only, so nothing is available for a caller to allocate
        // into — `freeBlocks` describes the image, `availableBlocks`
        // describes what this mount will let you do with it. The Btrfs
        // volume had this right and the others reached the same answer
        // only because they reported no free space at all.
        result.availableBlocks = 0

        result.ioSize = Int(info.ioSize)
        result.totalFiles = info.totalInodes ?? 0
        result.freeFiles = info.freeInodes ?? 0
        return result
    }
}
