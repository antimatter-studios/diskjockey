// The production XFS volume, driver, mount policy and device bridge,
// linked to the vendored rust-fs-xfs bundle and driven through FSKit's own
// volume methods over a Linux-made XFS image. Each change is read back
// after the volume is unmounted and mounted again read-only.
//
// What this proves is that FSKit's calls reach the driver and come back
// with the right counts, attributes and errnos. Whether the bytes on the
// image are a sound XFS volume is not ours to say: the Linux half,
// scripts/oracles/xfs-mutations-linux.sh, has xfs_repair -n, xfs_logprint,
// xfs_db and the kernel check that (diskjockey#322, #355).
//
// No fskitd is involved: the volume's methods are called in this process,
// the way the library tier's DiskJockeyXFSCoreTests call them, so no GUI
// session and no installed extension is needed.
//
//   tmp/xfs-oracle/xfs-mutations <image> <expected-dir>
import Foundation
import FSKit
import DiskJockeyLibrary

/// The image file as FSKit's block device: 512-byte logical blocks behind
/// 4 KiB physical ones, the shape a real disk gives the bridge.
private final class ImageDevice: XfsBlockDeviceIO {
    let blockSize: UInt64 = 512
    let physicalBlockSize: UInt64 = 4096
    let blockCount: UInt64
    let isWritable: Bool
    private let fd: Int32

    init(_ path: String, writable: Bool) throws {
        fd = Darwin.open(path, writable ? O_RDWR : O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var st = Darwin.stat()
        guard fstat(fd, &st) == 0 else { throw POSIXError(.EIO) }
        blockCount = UInt64(st.st_size) / 512
        isWritable = writable
    }
    deinit { Darwin.close(fd) }

    func read(into buffer: UnsafeMutableRawBufferPointer, startingAt offset: off_t, length: Int) throws -> Int {
        let n = Darwin.pread(fd, buffer.baseAddress, length, offset)
        guard n >= 0 else { throw POSIXError(.EIO) }
        return n
    }
    func write(from buffer: UnsafeRawBufferPointer, startingAt offset: off_t, length: Int) throws -> Int {
        guard isWritable else { throw POSIXError(.EROFS) }
        let n = Darwin.pwrite(fd, buffer.baseAddress, length, offset)
        guard n >= 0 else { throw POSIXError(.EIO) }
        return n
    }
    func flushMetadata() throws {
        guard Darwin.fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }
}

struct OracleFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct XfsMutationsOracle {
    static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw OracleFailure(description: message()) }
    }

    static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw OracleFailure(description: message) }
        return value
    }

    static func expect(_ code: POSIXErrorCode, _ what: String,
                       _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let error as POSIXError where error.code == code {
            return
        } catch {
            throw OracleFailure(description: "\(what): expected \(code), got \(error)")
        }
        throw OracleFailure(description: "\(what): expected \(code), got success")
    }

    /// Mount `image` the way XfsFileSystem.loadResource does: the policy
    /// from the options, the native handle from the bridge, a writable
    /// driver mount when the policy and the device allow one and the
    /// read-only mount when the driver refuses it, then the policy's
    /// verdict on the mounted driver.
    static func mount(_ image: String, options: [String]) throws -> XfsVolume {
        let policy = XfsMountPolicy(options: options)
        let device = try ImageDevice(image, writable: policy == .readWrite)
        let context = try XfsBlockDeviceContext(device: device)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()
        let handle = try XfsBlockDeviceBridge.makeHandle(contextPtr: contextPtr)
        var mounted: OpaquePointer?
        if policy.requestsWritableMount(deviceIsWritable: device.isWritable) {
            mounted = fs_xfs_mount_rw_with_fs_core_device(handle)
            if mounted == nil {
                let reason = fs_xfs_last_error().flatMap { String(cString: $0) } ?? "(no error set)"
                print("the driver refused a writable mount (errno \(fs_xfs_last_errno())): \(reason)")
            }
        }
        if mounted == nil {
            mounted = fs_xfs_mount_with_fs_core_device(handle)
        }
        fs_core_device_close(handle)
        guard let fs = mounted else {
            Unmanaged<XfsBlockDeviceContext>.fromOpaque(contextPtr).release()
            throw OracleFailure(description: "mount failed: errno \(fs_xfs_last_errno())")
        }
        let driver = XfsDriver(fs: fs)
        let access = try policy.authorize(deviceIsWritable: device.isWritable,
                                          mountedDriver: .success(driver.isWritable))
        return XfsVolume(volumeID: FSVolume.Identifier(), volumeName: FSFileName(string: "oracle"),
                         driver: driver, contextPtr: contextPtr, bsdName: "oracle",
                         stats: IOStatsCollector(label: "oracle", emit: { _ in }),
                         mountAccess: access)
    }

    static func unmount(_ volume: XfsVolume) async throws {
        try await volume.synchronize(flags: .wait)
        await volume.unmount()
    }

    static func lookup(_ volume: XfsVolume, _ path: String) async throws -> XfsItem {
        var item = try volume.rootItem()
        for name in path.split(separator: "/") {
            let found = try await volume.lookupItem(named: FSFileName(string: String(name)), inDirectory: item)
            guard let next = found.0 as? XfsItem else { throw OracleFailure(description: "not an XfsItem") }
            item = next
        }
        return item
    }

    static func contents(_ volume: XfsVolume, _ item: XfsItem) async throws -> [UInt8] {
        let size = Int(try await volume.attributes(FSItem.GetAttributesRequest(), of: item).size)
        var buffer = [UInt8](repeating: 0xEE, count: size)
        let n = try buffer.withUnsafeMutableBytes { try volume.readBytes(from: item, at: 0, into: $0) }
        try check(n == size, "read \(n) of \(size) bytes")
        return buffer
    }

    // MARK: - File data (diskjockey#322)

    /// What /data holds after the writes below: Linux wrote 4096 bytes of
    /// "L"; FSKit overwrites two ranges, writes past the end, grows the
    /// file by truncate and shrinks it again.
    static func expectedData() -> [UInt8] {
        var bytes = [UInt8](repeating: UInt8(ascii: "L"), count: 4096)
        bytes.replaceSubrange(0..<5, with: Array("HELLO".utf8))
        bytes.replaceSubrange(100..<103, with: Array("mid".utf8))
        bytes += [UInt8](repeating: 0, count: 10000 - 4096)
        bytes += Array("tail".utf8)
        bytes += [UInt8](repeating: 0, count: 15000 - bytes.count)
        return bytes
    }

    static func writeData(_ volume: XfsVolume) async throws {
        let data = try await lookup(volume, "data")
        var n = try await volume.write(contents: Data("HELLO".utf8), to: data, at: 0)
        try check(n == 5, "write at zero answered \(n)")
        n = try await volume.write(contents: Data("mid".utf8), to: data, at: 100)
        try check(n == 3, "overwrite answered \(n)")
        n = try await volume.write(contents: Data("tail".utf8), to: data, at: 10000)
        try check(n == 4, "write past the end answered \(n)")
        for size: UInt64 in [20000, 15000] {
            let request = FSItem.SetAttributesRequest()
            request.size = size
            let attributes = try await volume.setAttributes(request, on: data)
            try check(attributes.size == size, "truncate to \(size) answered \(attributes.size)")
            try check(request.wasAttributeConsumed(.size), "truncate to \(size) not consumed")
        }
        try check(try await contents(volume, data) == expectedData(), "data differs before remount")
        let statfs = volume.volumeStatistics
        try check(statfs.availableBlocks > 0, "the volume reports no free space")
    }

    static func readData(_ volume: XfsVolume) async throws {
        let data = try await lookup(volume, "data")
        try check(try await contents(volume, data) == expectedData(), "data differs after remount")
        try await expect(.EROFS, "write on the read-only remount") {
            _ = try await volume.write(contents: Data("x".utf8), to: data, at: 0)
        }
    }

    static func names(_ volume: XfsVolume, _ directory: XfsItem) throws -> Set<String> {
        var found = Set<String>()
        _ = try volume.entries(of: directory, after: 0, withAttributes: false) {
            found.insert($0.name.string ?? "?")
            return true
        }
        return found
    }

    // MARK: - Create and remove (diskjockey#326)

    static func writeNamespace(_ volume: XfsVolume) async throws {
        let root = try volume.rootItem()
        let request = FSItem.SetAttributesRequest()
        request.mode = 0o640
        request.uid = 1001
        request.gid = 1002
        let (made, _) = try await volume.createItem(named: FSFileName(string: "made.txt"), type: .file,
                                                    inDirectory: root, attributes: request)
        try check(request.consumedAttributes.contains([.mode, .uid, .gid]), "create did not consume mode and owner")
        let file = try require(made as? XfsItem, "createItem answered no XfsItem")
        let n = try await volume.write(contents: Data("made by FSKit".utf8), to: file, at: 0)
        try check(n == 13, "write to the new file answered \(n)")

        let dirRequest = FSItem.SetAttributesRequest()
        dirRequest.mode = 0o750
        let (dir, _) = try await volume.createItem(named: FSFileName(string: "newdir"), type: .directory,
                                                   inDirectory: root, attributes: dirRequest)
        let newdir = try require(dir as? XfsItem, "createItem answered no XfsItem")
        _ = try await volume.createItem(named: FSFileName(string: "inner"), type: .file,
                                        inDirectory: newdir, attributes: FSItem.SetAttributesRequest())
        try await expect(.EEXIST, "create over a name") {
            _ = try await volume.createItem(named: FSFileName(string: "made.txt"), type: .file,
                                            inDirectory: root, attributes: FSItem.SetAttributesRequest())
        }

        for name in ["doomed", "emptydir"] {
            let item = try await lookup(volume, name)
            try await volume.removeItem(item, named: FSFileName(string: name), fromDirectory: root)
        }
        let full = try await lookup(volume, "fulldir")
        try await expect(.ENOTEMPTY, "rmdir of a directory holding a name") {
            try await volume.removeItem(full, named: FSFileName(string: "fulldir"), fromDirectory: root)
        }
        try await checkNamespace(volume)
    }

    static func checkNamespace(_ volume: XfsVolume) async throws {
        let root = try volume.rootItem()
        let listed = try names(volume, root)
        try check(listed.isSuperset(of: ["data", "made.txt", "newdir", "fulldir"]), "root lists \(listed)")
        try check(listed.isDisjoint(with: ["doomed", "emptydir"]), "removed names still listed: \(listed)")
        let file = try await lookup(volume, "made.txt")
        let attributes = try await volume.attributes(FSItem.GetAttributesRequest(), of: file)
        try check(attributes.mode & 0o7777 == 0o640, "made.txt mode \(String(attributes.mode, radix: 8))")
        try check(attributes.uid == 1001 && attributes.gid == 1002, "made.txt owner \(attributes.uid):\(attributes.gid)")
        try check(try await contents(volume, file) == Array("made by FSKit".utf8), "made.txt contents")
        try check(try names(volume, try await lookup(volume, "newdir")) == ["inner"], "newdir does not hold inner")
        try check(try await contents(volume, try await lookup(volume, "fulldir/keep")) == Array("keep\n".utf8),
                  "fulldir/keep changed")
    }

    // MARK: - Rename and links (diskjockey#327)

    static func rename(_ volume: XfsVolume, _ from: String, to: String) async throws {
        let parent = { (path: String) -> String in path.split(separator: "/").dropLast().joined(separator: "/") }
        let base = { (path: String) -> String in String(path.split(separator: "/").last!) }
        let root = try volume.rootItem()
        let fromDir = parent(from).isEmpty ? root : try await lookup(volume, parent(from))
        let toDir = parent(to).isEmpty ? root : try await lookup(volume, parent(to))
        let item = try await lookup(volume, from)
        _ = try await volume.renameItem(item, inDirectory: fromDir, named: FSFileName(string: base(from)),
                                        to: FSFileName(string: base(to)), inDirectory: toDir, overItem: nil)
    }

    static func writeRenameLink(_ volume: XfsVolume) async throws {
        try await rename(volume, "moveme", to: "renamed")
        try await rename(volume, "dirA/sub", to: "dirB/sub2")
        try await rename(volume, "replacer", to: "victim")
        let source = try await lookup(volume, "linksrc")
        _ = try await volume.createLink(to: source, named: FSFileName(string: "hard"),
                                        inDirectory: try await lookup(volume, "dirB"))
        try await expect(.ENOTSUP, "createSymbolicLink") {
            _ = try await volume.createSymbolicLink(
                named: FSFileName(string: "sym"), inDirectory: try volume.rootItem(),
                attributes: FSItem.SetAttributesRequest(), linkContents: FSFileName(string: "renamed"))
        }
        try await checkRenameLink(volume)
    }

    static func checkRenameLink(_ volume: XfsVolume) async throws {
        let listed = try names(volume, try volume.rootItem())
        try check(listed.isSuperset(of: ["renamed", "victim", "linksrc", "dirA", "dirB"]), "root lists \(listed)")
        try check(listed.isDisjoint(with: ["moveme", "replacer", "sym"]), "old names still listed: \(listed)")
        try check(try await contents(volume, try await lookup(volume, "renamed")) == Array("move me\n".utf8), "renamed")
        try check(try await contents(volume, try await lookup(volume, "victim")) == Array("new\n".utf8), "victim was not replaced")
        try check(try await contents(volume, try await lookup(volume, "dirB/sub2/f")) == Array("deep\n".utf8), "dirB/sub2/f")
        try check(try names(volume, try await lookup(volume, "dirA")).isEmpty, "dirA still holds sub")
        let source = try await lookup(volume, "linksrc")
        let hard = try await lookup(volume, "dirB/hard")
        try check(source.inode == hard.inode, "the hard link names another inode")
        let attributes = try await volume.attributes(FSItem.GetAttributesRequest(), of: hard)
        try check(attributes.linkCount == 2, "linksrc has \(attributes.linkCount) links")
    }

    // MARK: - Attributes and extended attributes (diskjockey#328)

    static func writeAttributes(_ volume: XfsVolume) async throws {
        let item = try await lookup(volume, "attrs")
        let request = FSItem.SetAttributesRequest()
        request.mode = 0o600
        request.uid = 1002
        request.gid = 1003
        request.accessTime = timespec(tv_sec: -1, tv_nsec: 123_456_789)
        request.modifyTime = timespec(tv_sec: 1_800_000_000, tv_nsec: 987_654_321)
        _ = try await volume.setAttributes(request, on: item)
        try check(request.consumedAttributes == [.mode, .uid, .gid, .accessTime, .modifyTime],
                  "setAttributes consumed \(request.consumedAttributes.rawValue)")
        let partial = FSItem.SetAttributesRequest()
        partial.gid = 1004
        _ = try await volume.setAttributes(partial, on: item)
        try check(partial.consumedAttributes == [.gid], "a partial request consumed more than gid")

        let ops: any FSVolume.XattrOperations = volume
        let protected = try await lookup(volume, "protected")
        try check([UInt8](try await ops.xattr(named: FSFileName(string: "dj"), of: protected)) == Array("original".utf8),
                  "user.dj from Linux does not read as dj")
        try await ops.setXattr(named: FSFileName(string: "dj"), to: Data("changed".utf8), on: protected, policy: .mustReplace)
        try await ops.setXattr(named: FSFileName(string: "com.apple.test"), to: Data([0, 1, 2, 255]),
                               on: protected, policy: .mustCreate)
        try await expect(.EEXIST, "mustCreate over an attribute") {
            try await ops.setXattr(named: FSFileName(string: "dj"), to: Data([1]), on: protected, policy: .mustCreate)
        }
        try await expect(.ENOATTR, "a missing attribute") {
            _ = try await ops.xattr(named: FSFileName(string: "absent"), of: protected)
        }
        try await ops.setXattr(named: FSFileName(string: "gone"), to: Data([7]), on: protected, policy: .alwaysSet)
        try await ops.setXattr(named: FSFileName(string: "gone"), to: nil, on: protected, policy: .delete)
        // A macOS ACL would change meaning stored as bytes or as a POSIX ACL.
        try await expect(.ENOTSUP, "a macOS ACL") {
            try await ops.setXattr(named: FSFileName(string: "com.apple.system.Security"), to: Data([1]),
                                   on: protected, policy: .alwaysSet)
        }
        try await checkAttributes(volume)
    }

    static func checkAttributes(_ volume: XfsVolume) async throws {
        let attributes = try await volume.attributes(FSItem.GetAttributesRequest(), of: try await lookup(volume, "attrs"))
        try check(attributes.mode & 0o7777 == 0o600, "attrs mode \(String(attributes.mode, radix: 8))")
        try check(attributes.uid == 1002 && attributes.gid == 1004, "attrs owner \(attributes.uid):\(attributes.gid)")
        // The shared FSKit mapping reports mtime for all timestamp fields;
        // xfs-mutations-linux.sh verifies the stored atime and nanoseconds.
        try check(attributes.modifyTime.tv_sec == 1_800_000_000, "attrs mtime \(attributes.modifyTime.tv_sec)")
        let ops: any FSVolume.XattrOperations = volume
        let protected = try await lookup(volume, "protected")
        // Linux's POSIX ACL on this file is a system.posix_acl_access
        // attribute: it is kept, and it is not a macOS caller's to list.
        let listed = Set(try await ops.xattrs(of: protected).compactMap(\.string))
        try check(listed == ["dj", "com.apple.test"], "protected lists \(listed)")
        try check([UInt8](try await ops.xattr(named: FSFileName(string: "dj"), of: protected)) == Array("changed".utf8), "dj")
        try check([UInt8](try await ops.xattr(named: FSFileName(string: "com.apple.test"), of: protected)) == [0, 1, 2, 255],
                  "com.apple.test")
    }

    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            print("usage: xfs-mutations <image> <expected-dir>")
            exit(2)
        }
        let (image, expected) = (arguments[1], URL(fileURLWithPath: arguments[2]))
        do {
            let writable = try mount(image, options: [])
            try check(writable.allowsWrites, "a writable image on writable hardware mounted read-only")
            try await writeData(writable)
            try await writeNamespace(writable)
            try await writeRenameLink(writable)
            try await writeAttributes(writable)
            try await unmount(writable)

            let readOnly = try mount(image, options: ["ro"])
            try check(!readOnly.allowsWrites, "an ro mount allows writes")
            try await readData(readOnly)
            try await checkNamespace(readOnly)
            try await checkRenameLink(readOnly)
            try await checkAttributes(readOnly)
            try await expect(.EROFS, "setXattr on the read-only remount") {
                try await (readOnly as any FSVolume.XattrOperations).setXattr(
                    named: FSFileName(string: "dj"), to: Data([1]),
                    on: try await lookup(readOnly, "protected"), policy: .alwaysSet)
            }
            try await unmount(readOnly)

            try Data(expectedData()).write(to: expected.appendingPathComponent("data"))
            print("xfs-mutations: every FSKit change read back after a read-only remount")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }
}
