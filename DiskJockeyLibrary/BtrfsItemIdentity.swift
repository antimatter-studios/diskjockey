//
// BtrfsItemIdentity.swift — the FSKit identifier of a Btrfs item is its
// (tree, inode) pair, never a bare number (diskjockey#261).
//
// WHY A PAIR. A Btrfs inode number means something only inside one tree:
// every subvolume has its own inode namespace, and every subvolume's top
// directory is inode 256 — as is the mounted tree's. A directory entry can
// also name a whole subvolume, and then the number it carries is a TREE id
// (fs_btrfs.h: `is_subvolume`). The volume used to hand FSKit the dirent's
// number raw, so:
//
//   • a listed subvolume showed up under its tree id. The first subvolume
//     ever created is tree 256, so it was listed with the volume root's id;
//   • the same inode number in two subvolumes was one id, and FileIDCache,
//     which keys on the id and replaces on a path mismatch, evicted one
//     subvolume's item for the other's.
//
// THE DECISION (made 2026-09-30 for #261, owner unavailable): an item is a
// `BtrfsObjectKey` — the tree it lives in plus its inode in that tree —
// and FSKit's identifier is that key packed into 64 bits:
//
//     fileID = ordinal << 48 | inode
//
// `ordinal` is 0 for the mounted tree, so a volume with no subvolumes keeps
// exactly the identifiers it had before. Each other tree gets the next
// ordinal the first time the mount meets it. Ordinals, not tree ids,
// because tree ids are 64-bit and would not leave room for an inode; the
// cost is that a subvolume's identifiers are stable for one mount only,
// which is all FSKit asks of them. 48 bits of inode is 2.8 × 10^14 objects
// in one tree, and 16 of ordinal is 65,535 subvolumes met in one mount.
// Anything past either is refused with EOVERFLOW rather than truncated into
// another object's identifier: a failure a person sees beats Finder quietly
// showing one file's contents under another's name.
//
// A LISTED SUBVOLUME IS ITS TOP DIRECTORY. The entry naming subvolume T is
// the key (T, 256), which is the item a lookup crossing into T arrives at.
// A lookup cannot say which tree it crossed into — fs_btrfs_attr_t carries
// no tree id — so it recognises the crossing by the inode it lands on and
// asks the parent directory's listing for the tree (`lookupKey`).
//
// WHAT am-fs-btrfs 0.7.0 CAN DO WITH THIS. Its fs_btrfs_stat, read_file and
// readlink resolve paths with `lookup_path`, which refuses to cross a
// subvolume boundary (ENOTSUP); only fs_btrfs_dir_open crosses. So today a
// subvolume is listed, under its own identifier, and cannot be entered. The
// crossing half of `lookupKey` is there so that a driver whose stat crosses
// gets agreeing identifiers without a second change here.
//

import Foundation
import os

/// The tree an inode number is an inode of.
public enum BtrfsTree: Hashable, Sendable {
    /// The tree the volume was mounted at — the default subvolume. Its
    /// number is not asked for because nothing here needs it: the C ABI
    /// does not say it, and the mounted tree is ordinal 0 whatever it is.
    case mounted
    /// Another subvolume, by its tree id.
    case subvolume(UInt64)
}

/// One object on the volume: an inode, and the tree it is an inode of.
public struct BtrfsObjectKey: Hashable, Sendable, CustomStringConvertible {
    public let tree: BtrfsTree
    public let inode: UInt64

    public init(tree: BtrfsTree, inode: UInt64) {
        self.tree = tree
        self.inode = inode
    }

    public var description: String {
        switch tree {
        case .mounted: return "inode \(inode) of the mounted tree"
        case .subvolume(let id): return "inode \(inode) of subvolume \(id)"
        }
    }
}

public enum BtrfsIdentity {
    /// `BTRFS_FIRST_FREE_OBJECTID`: the inode of every tree's top
    /// directory. In its own tree it is the root and nobody's child, so a
    /// child that has it has crossed into another tree.
    public static let subvolumeRootInode: UInt64 = 256

    /// `BTRFS_EMPTY_SUBVOL_DIR_OBJECTID`: the empty directory the kernel
    /// shows for a subvolume entry with no ROOT_REF behind it — how a
    /// snapshot's copy of a nested subvolume looks. No tree has an inode 2.
    public static let emptySubvolumeDirInode: UInt64 = 2

    /// The object a directory entry names. An entry flagged
    /// `is_subvolume` carries a tree id, and names that tree's top
    /// directory; any other entry is an inode of the listing directory's
    /// own tree.
    public static func entryKey(inDirectoryOf tree: BtrfsTree,
                                direntInode: UInt64,
                                isSubvolume: Bool) -> BtrfsObjectKey {
        isSubvolume
            ? BtrfsObjectKey(tree: .subvolume(direntInode), inode: subvolumeRootInode)
            : BtrfsObjectKey(tree: tree, inode: direntInode)
    }

    /// The object a lookup found, from the inode its stat reported.
    ///
    /// A child reporting inode 256 or 2 has crossed a subvolume boundary,
    /// and stat does not say into which tree. `subvolumeEntry` answers
    /// that from the parent's listing: the tree id of the entry of this
    /// name if it is flagged as a subvolume, else nil. It is called only
    /// for a crossing, because it lists the directory.
    ///
    /// - Throws: `EIO` when stat says the child is a subvolume's top
    ///   directory and the parent does not list it as one. There is then
    ///   no tree to put it in, and the mounted tree's guess would be the
    ///   volume root's identifier.
    public static func lookupKey(inDirectoryOf tree: BtrfsTree,
                                 statInode: UInt64,
                                 subvolumeEntry: () -> UInt64?) throws -> BtrfsObjectKey {
        guard statInode == subvolumeRootInode || statInode == emptySubvolumeDirInode else {
            return BtrfsObjectKey(tree: tree, inode: statInode)
        }
        guard let subvolume = subvolumeEntry() else { throw POSIXError(.EIO) }
        return entryKey(inDirectoryOf: tree, direntInode: subvolume, isSubvolume: true)
    }
}

/// Issues the FSKit file identifiers for one mount, and reads them back.
///
/// One per mounted volume, living as long as it: the ordinals it hands out
/// are what make an identifier mean the same object for the whole mount.
public final class BtrfsIdentifierSpace: @unchecked Sendable {

    /// Low bits of an identifier holding the inode.
    public static let inodeBits = 48

    private static let inodeMask: UInt64 = (1 << UInt64(inodeBits)) - 1
    private static let maxOrdinal: UInt64 = UInt64.max >> UInt64(inodeBits)

    private struct Ordinals {
        var byTree: [UInt64: UInt64] = [:]
        var byOrdinal: [UInt64: UInt64] = [:]
    }

    private let ordinals = OSAllocatedUnfairLock(initialState: Ordinals())

    public init() {}

    /// The identifier for `key`, the same every time within this space.
    ///
    /// - Throws: `EOVERFLOW` for an inode wider than `inodeBits`, or for a
    ///   subvolume beyond the 65,535th this mount has met.
    public func fileID(for key: BtrfsObjectKey) throws -> UInt64 {
        guard key.inode <= Self.inodeMask else { throw POSIXError(.EOVERFLOW) }
        let ordinal: UInt64
        switch key.tree {
        case .mounted:
            ordinal = 0
        case .subvolume(let tree):
            ordinal = try ordinals.withLock { state in
                if let known = state.byTree[tree] { return known }
                let next = UInt64(state.byTree.count) + 1
                guard next <= Self.maxOrdinal else { throw POSIXError(.EOVERFLOW) }
                state.byTree[tree] = next
                state.byOrdinal[next] = tree
                return next
            }
        }
        return ordinal << UInt64(Self.inodeBits) | key.inode
    }

    /// The object `fileID` was issued for.
    ///
    /// - Throws: `EINVAL` for an identifier naming a tree this space never
    ///   issued an ordinal for.
    public func key(forFileID fileID: UInt64) throws -> BtrfsObjectKey {
        let ordinal = fileID >> UInt64(Self.inodeBits)
        let inode = fileID & Self.inodeMask
        if ordinal == 0 { return BtrfsObjectKey(tree: .mounted, inode: inode) }
        guard let tree = ordinals.withLock({ $0.byOrdinal[ordinal] }) else {
            throw POSIXError(.EINVAL)
        }
        return BtrfsObjectKey(tree: .subvolume(tree), inode: inode)
    }
}
