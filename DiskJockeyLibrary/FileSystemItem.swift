//
// FileSystemItem.swift — generic FSItem subclass shared by every
// per-flavour FSKit extension (ext4, NTFS, …), plus the per-flavour
// tags and legacy-name forwarders.
//
// Why a generic instead of one class per filesystem:
//
//   • EXT4Item and NTFSItem were structurally identical — an identity
//     value, a path, and an optional parent identity — diverging only
//     in the integer width of the identity (UInt32 inode vs UInt64
//     MFT record). Two near-duplicate classes diverge over time and
//     hide the fact that the shape is one concept.
//
//   • Adding a third filesystem (HFS+, exFAT, …) becomes a typealias
//     plus a small extension, not another copy of the same 35-line
//     skeleton.
//
// The `Tag` phantom parameter is what makes this safer than a single
// concrete type with a `UInt64` id field. `FileSystemItem<EXT4Tag>`
// and `FileSystemItem<NTFSTag>` are statically distinct, so the
// compiler refuses any code that accidentally feeds an ext4 inode
// into an NTFS code path. The previous two-class scheme caught that
// only because the classes were nominally different; this preserves
// the guarantee while collapsing the storage.
//

import FSKit
import Foundation

// MARK: - Generic

/// Marker for a filesystem flavour. Picks the integer width used for
/// per-object identity (inode for ext4, MFT record for NTFS). A new
/// filesystem only needs an enum that conforms to this and points its
/// `ID` typealias at the right unsigned integer type.
public protocol FileSystemTag {
    associatedtype ID: Hashable & Sendable
}

/// Generic `FSItem` subclass parameterised by `Tag`. The tag controls
/// the static identity type, so cross-filesystem ID mix-ups become a
/// compile error rather than a runtime corruption. FSKit hands these
/// back to us by their `FSItem` base type — the generic specialisation
/// is invisible to the framework.
///
/// `open` rather than `final`: tests can subclass to spy on inits if
/// ever needed, and a future per-flavour subclass (e.g. one that
/// caches a stat) can extend this without forking the storage.
open class FileSystemItem<Tag: FileSystemTag>: FSItem {

    /// Filesystem-defined identity — ext4 calls this an inode, NTFS
    /// calls it an MFT record number. Persisted across the FSKit-↔-
    /// kernel round-trip, so it must be unique within the volume for
    /// the lifetime of the mount.
    public let id: Tag.ID

    /// Absolute path within the volume (e.g. `/etc/passwd`). Used by
    /// every backend op — the FSKit-side identity is a `UInt64`
    /// fileID that the volume translates back to this path via its
    /// item cache, but the backend itself is always path-driven.
    public let path: String

    /// Parent directory's identity. `nil` only for the root item,
    /// whose parent FSKit defines as the sentinel `FSItemIDParentOfRoot`
    /// (1). Stored at construction time so the FSKit attribute-fetch
    /// path doesn't need a second stat just to fill in `parentID`
    /// (bit 9 of the standard attribute set).
    public let parentID: Tag.ID?

    public init(id: Tag.ID, path: String, parentID: Tag.ID?) {
        self.id = id
        self.path = path
        self.parentID = parentID
        super.init()
    }
}

// MARK: - ext4 specialisation

/// Phantom tag selecting `UInt32` identity for ext4 inodes.
public enum EXT4Tag: FileSystemTag {
    public typealias ID = UInt32
}

/// Source-compatible alias for the per-FS class that previously lived
/// in DiskJockeyEXT4.
public typealias EXT4Item = FileSystemItem<EXT4Tag>

public extension FileSystemItem where Tag == EXT4Tag {
    /// ext4 inode number — legacy spelling for `id`.
    var inode: UInt32 { id }

    /// Parent directory's inode — legacy spelling for `parentID`.
    var parentInode: UInt32? { parentID }

    /// Legacy initializer matching the original `EXT4Item(inode:path:
    /// parentInode:)` signature so the volume code didn't need to be
    /// rewritten when this collapsed into the generic.
    convenience init(inode: UInt32, path: String, parentInode: UInt32?) {
        self.init(id: inode, path: path, parentID: parentInode)
    }
}

// MARK: - NTFS specialisation

/// Phantom tag selecting `UInt64` identity for NTFS MFT records.
public enum NTFSTag: FileSystemTag {
    public typealias ID = UInt64
}

/// Source-compatible alias for the per-FS class that previously lived
/// in DiskJockeyNTFS.
public typealias NTFSItem = FileSystemItem<NTFSTag>

public extension FileSystemItem where Tag == NTFSTag {
    /// NTFS file record number (MFT index) — legacy spelling for `id`.
    var fileRecordNumber: UInt64 { id }

    /// Parent directory's MFT record — legacy spelling for `parentID`.
    var parentRecordNumber: UInt64? { parentID }

    /// Legacy initializer matching the original `NTFSItem(
    /// fileRecordNumber:path:parentRecordNumber:)` signature.
    convenience init(fileRecordNumber: UInt64, path: String,
                     parentRecordNumber: UInt64?) {
        self.init(id: fileRecordNumber, path: path,
                  parentID: parentRecordNumber)
    }
}
