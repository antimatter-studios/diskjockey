/*
 * EXT4Item.swift — FSItem subclass representing an ext4 filesystem object.
 *
 * Each EXT4Item tracks its inode number and full path within the ext4 fs.
 * The path is used by the bridge layer for all operations.
 *
 * MIT License — see LICENSE
 */

import FSKit
import Foundation

/// Represents a file, directory, or symlink in the ext4 filesystem.
final class EXT4Item: FSItem {

    /// ext4 inode number
    let inode: UInt32

    /// Full path within the ext4 filesystem (e.g. "/etc/passwd")
    let path: String

    /// Inode of the directory this item lives in. `nil` only for the
    /// root directory — its parent is `FSItemIDParentOfRoot` (1), a
    /// constant FSKit defines, so we don't need to store it.
    /// FSKit's standard attribute set requires `parentID` (bit 9);
    /// every code path that constructs an EXT4Item already knows the
    /// parent dir, so we thread it through here rather than doing a
    /// second stat at attribute-fetch time.
    let parentInode: UInt32?

    init(inode: UInt32, path: String, parentInode: UInt32?) {
        self.inode = inode
        self.path = path
        self.parentInode = parentInode
        super.init()
    }
}
