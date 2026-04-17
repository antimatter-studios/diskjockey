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

    init(inode: UInt32, path: String) {
        self.inode = inode
        self.path = path
        super.init()
    }
}
