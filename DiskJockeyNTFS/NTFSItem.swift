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

    /// MFT record of the directory this item lives in. `nil` only for
    /// the root directory — its parent is `FSItemIDParentOfRoot` (1),
    /// the FSKit-defined sentinel. FSKit's standard attribute set
    /// requires `parentID` (bit 9); every code path that constructs an
    /// NTFSItem already knows the parent dir, so we thread it through
    /// rather than doing an extra stat at attribute-fetch time.
    let parentRecordNumber: UInt64?

    init(fileRecordNumber: UInt64, path: String,
         parentRecordNumber: UInt64?) {
        self.fileRecordNumber = fileRecordNumber
        self.path = path
        self.parentRecordNumber = parentRecordNumber
        super.init()
    }
}
