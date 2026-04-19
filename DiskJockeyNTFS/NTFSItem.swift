/*
 * NTFSItem.swift — FSItem subclass representing an NTFS filesystem object.
 *
 * Each NTFSItem tracks its file record number and full path within the NTFS fs.
 *
 * MIT License — see LICENSE
 */

import FSKit
import Foundation

/// Represents a file, directory, or symlink in the NTFS filesystem.
final class NTFSItem: FSItem {

    /// NTFS file record number (MFT index)
    let fileRecordNumber: UInt64

    /// Full path within the NTFS filesystem (e.g. "/Windows/System32")
    let path: String

    init(fileRecordNumber: UInt64, path: String) {
        self.fileRecordNumber = fileRecordNumber
        self.path = path
        super.init()
    }
}
