//
//  ReadOnlyVolumeDriver.swift — what a read-only FSKit volume asks of its
//  driver, as a protocol a test can stand in for.
//
//  WHY THIS EXISTS
//
//  The read-only volumes called their driver's `fs_<fs>_*` C functions
//  directly, so a volume could not be compiled without the Rust static
//  library and its bridging header. That is why every test of them was a
//  hand-written mirror of the volume's wiring (diskjockey#196), and a
//  mirror asserts only what its author wrote into it: the XFS mirror
//  expected a failed read to throw, while the volume it claimed to mirror
//  answered every failed read with zero bytes, which FSKit takes as the
//  end of the file.
//
//  With the C calls behind this protocol, the volume is pure Swift over
//  pure Swift types and builds in a SwiftPM target `swift test` reaches.
//  Each extension keeps one small file that implements this protocol with
//  its C ABI, and that file is the only one the tests cannot load.
//
//  THE CONTRACT
//
//  It is the drivers' own, restated without their C types. Paths are
//  VolumePath and names are bytes, never String: a String repairs invalid
//  UTF-8 and would name another file (diskjockey#219). Every call that
//  can fail reports it the drivers' way — a nil, a false or a negative
//  count — and leaves the reason in `lastErrno()`, which is the driver's
//  per-thread `fs_<fs>_last_errno`. The protocol deliberately does not turn
//  failures into Swift errors: deciding what a failure means to FSKit is
//  the volume's job, and it is the part worth testing.
//

import FSKit
import Foundation

/// One directory entry, as a read-only driver lists it. The name is the
/// dirent's bytes, whether or not they are valid UTF-8.
public struct ReadOnlyDirectoryEntry: Equatable, Sendable {
    public var name: [UInt8]
    /// The entry's inode — except when `isSubvolume` is set, when it is
    /// the id of the tree the entry names.
    public var inode: UInt64
    public var fileType: ReadOnlyFileType
    /// The entry names a whole subvolume, so `inode` is a TREE id, not an
    /// inode of the listing directory's tree. Only Btrfs has these
    /// (fs_btrfs.h, `is_subvolume`); every other driver leaves it false
    /// (diskjockey#261).
    public var isSubvolume: Bool

    public init(name: [UInt8], inode: UInt64, fileType: ReadOnlyFileType,
                isSubvolume: Bool = false) {
        self.name = name
        self.inode = inode
        self.fileType = fileType
        self.isSubvolume = isSubvolume
    }
}

/// One entry ready for `FSDirectoryEntryPacker.packEntry`, which is what
/// a volume's enumeration produces. FSKit's packer has no public
/// initialiser, so the volumes build these and hand them to a closure;
/// in the extension the closure is the packer, and in a test it is an
/// array.
public struct PackableDirectoryEntry {
    public var name: FSFileName
    public var itemType: FSItem.ItemType
    public var itemID: FSItem.Identifier
    public var nextCookie: FSDirectoryCookie
    public var attributes: FSItem.Attributes?

    public init(name: FSFileName, itemType: FSItem.ItemType,
                itemID: FSItem.Identifier, nextCookie: FSDirectoryCookie,
                attributes: FSItem.Attributes?) {
        self.name = name
        self.itemType = itemType
        self.itemID = itemID
        self.nextCookie = nextCookie
        self.attributes = attributes
    }

    /// Packs this entry: false when the packer is full.
    public func pack(into packer: FSDirectoryEntryPacker) -> Bool {
        packer.packEntry(name: name, itemType: itemType, itemID: itemID,
                         nextCookie: nextCookie, attributes: attributes)
    }
}

/// What the directory walk found when it stopped.
public enum ReadOnlyDirectoryWalk: Equatable, Sendable {
    /// The directory could not be opened.
    case openFailed
    /// Every entry was offered, or the visitor asked to stop.
    case finished
    /// The driver stopped partway through with an error, or handed back
    /// an entry whose name could not be read. The entries already offered
    /// are real; the ones after them are missing.
    case failedPartway
}

/// The calls a read-only volume makes into its driver.
public protocol ReadOnlyVolumeDriver: AnyObject {
    /// Volume-wide figures for `statfs`, or nil when the driver cannot
    /// report them.
    func volumeInfo() -> ReadOnlyVolumeInfo?

    /// Attributes of `path`, not following a final symbolic link. Nil on
    /// failure, with `lastErrno()` set.
    func stat(_ path: VolumePath) -> ReadOnlyFileAttributes?

    /// Offers each entry of the directory at `path` to `visit`, in the
    /// driver's order, until `visit` returns false or the entries run out.
    func walkDirectory(_ path: VolumePath,
                       _ visit: (ReadOnlyDirectoryEntry) -> Bool) -> ReadOnlyDirectoryWalk

    /// Reads up to `buffer.count` bytes of `path` from `offset`: the count
    /// read, 0 at end of file, negative on failure with `lastErrno()` set.
    func read(_ path: VolumePath, at offset: UInt64,
              into buffer: UnsafeMutableRawBufferPointer) -> Int64

    /// `fs_<fs>_readlink` with the handle and the path bound; see
    /// `SymlinkTarget` for the return-value contract.
    func readlink(_ path: VolumePath, _ buffer: UnsafeMutablePointer<CChar>,
                  _ size: Int) -> Int32

    /// The errno of this thread's most recent failed call.
    func lastErrno() -> Int32

    /// Releases the handle. Called at most once.
    func unmount()
}

public extension ReadOnlyVolumeDriver {
    /// `lastErrno()` as a POSIX error, EIO when the driver set none: a
    /// failure with no reason is still a failure, and EIO is the errno
    /// that says so without claiming a cause.
    func lastPOSIXError() -> POSIXError {
        let errno = lastErrno()
        guard errno != 0, let code = POSIXErrorCode(rawValue: errno) else {
            return POSIXError(.EIO)
        }
        return POSIXError(code)
    }
}
