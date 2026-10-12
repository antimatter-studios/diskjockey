//
//  BcachefsImageTests.swift — the REAL BcachefsVolume over the REAL
//  BcachefsDriver, linked to the bundle library, on bcachefs images the
//  reference tools made.
//
//  WHERE THE EXPECTED VALUES COME FROM
//  -----------------------------------
//  Never from this adapter. The images and what is known about them were
//  made by the reference bcachefs tools in rust-fs-bcachefs's CI
//  (Fixtures/PROVENANCE.txt, scripts/bcachefs-fixtures.sh):
//
//    kernel.json            the reference kernel module's mount, listing the
//                           tree it wrote: types, modes, inode numbers, link
//                           counts, sizes, SHA-256 of contents, link targets.
//    kernel.dirents.txt     the reference lister's dirents: which root
//                           entries are subvolumes.
//    xattr-lengths.*.txt    the reference lister's dirents and xattrs.
//    base.super.txt         the reference printer's superblock.
//
//  What a write test expects is what it wrote, and it reads that back
//  through the driver's own C ABI on a fresh handle after the volume is
//  gone — not through the volume that wrote it.
//
//  NOTHING SKIPS. A fixture that is not there fails the test, naming
//  scripts/bcachefs-fixtures.sh; a library that is not built fails the
//  build, and scripts/test-library.sh names `make vendor-bundles` first.
//

import CryptoKit
import Foundation
import FSKit
import Testing
import CBcachefsBundle
@testable import DiskJockeyBCACHEFSCore
@testable import DiskJockeyLibrary

// MARK: - Fixtures

private enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func url(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FixtureMissing(name: name)
        }
        return url
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    /// A private, writable copy of a gzip'd image, removed when the test
    /// is done with it.
    static func image(_ name: String) throws -> URL {
        let gz = try url("\(name).img.gz")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bcachefs-image-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("\(name).img")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let gunzip = Process()
        gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gunzip.arguments = ["-dc", gz.path]
        gunzip.standardOutput = try FileHandle(forWritingTo: out)
        try gunzip.run()
        gunzip.waitUntilExit()
        guard gunzip.terminationStatus == 0 else {
            throw POSIXError(.EIO)
        }
        return out
    }

    /// Removes the private copy `image` made.
    static func discard(_ image: URL) {
        try? FileManager.default.removeItem(at: image.deletingLastPathComponent())
    }
}

private struct FixtureMissing: Error, CustomStringConvertible {
    let name: String
    var description: String {
        "DiskJockeyBCACHEFSCoreTests/Fixtures/\(name) is missing: it is committed with "
            + "the tests; restore it, or remake the set with `chore fixtures:bcachefs` "
            + "(scripts/bcachefs-fixtures.sh)"
    }
}

/// One entry of kernel.json.
private struct ManifestEntry {
    var path: String
    var type: String
    var mode: UInt32
    var inode: UInt64
    var linkCount: UInt32
    var size: UInt64?
    var sha256: String?
    var target: String?
}

private func kernelManifest() throws -> [ManifestEntry] {
    let data = try Data(contentsOf: Fixture.url("kernel.json"))
    let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    return (root["entries"] as! [[String: Any]]).map { e in
        ManifestEntry(path: e["path"] as! String, type: e["type"] as! String,
                      mode: (e["mode"] as! NSNumber).uint32Value,
                      inode: (e["ino"] as! NSNumber).uint64Value,
                      linkCount: (e["nlink"] as! NSNumber).uint32Value,
                      size: (e["size"] as? NSNumber)?.uint64Value,
                      sha256: e["sha256"] as? String,
                      target: e["target"] as? String)
    }
}

/// One line of a reference lister's listing: `ino:offset:snap ... : rest`.
private struct ListedKey {
    var inode: UInt64
    var rest: String
}

private func listed(_ text: String, type: String) -> [ListedKey] {
    text.split(separator: "\n").compactMap { line in
        guard line.contains(" type \(type) "),
              let typeRange = line.range(of: " type \(type) "),
              let colon = line.range(of: "  : ") else { return nil }
        let pos = line[typeRange.upperBound...].split(separator: " ")[0]
        guard let ino = UInt64(pos.split(separator: ":")[0]) else { return nil }
        return ListedKey(inode: ino, rest: String(line[colon.upperBound...]))
    }
}

/// The names of the root's subvolume dirents, from the reference lister.
private func rootSubvolumes() throws -> Set<String> {
    Set(listed(try Fixture.text("kernel.dirents.txt"), type: "dirent")
        .filter { $0.inode == 4096 && $0.rest.hasSuffix(" type subvol") }
        .map { String($0.rest.split(separator: " ")[0]) })
}

// MARK: - The adapter over an image

private struct Mounted {
    let volume: BcachefsVolume
    let driver: BcachefsDriver
    let image: URL
}

/// The volume over the driver over an fs_core file device on `image`, as
/// the extension builds it over FSKit's block device.
private func mount(_ image: URL, writable: Bool,
                   policy: BcachefsMountPolicy? = nil) throws -> Mounted {
    guard let device = fs_core_file_open(image.path, writable) else {
        throw POSIXError(.EIO)
    }
    let driver = try BcachefsDriver(device: device, writable: writable)
    let volume = BcachefsVolume(
        volumeID: FSVolume.Identifier(uuid: UUID()), volumeName: FSFileName(string: "test"),
        backend: driver, policy: policy ?? (writable ? .readWrite : .readOnly),
        bsdName: "disk9s1", stats: IOStatsCollector(label: "test", emit: { _ in }))
    return Mounted(volume: volume, driver: driver, image: image)
}

/// Walks `path` from the root through `lookupItem`, as FSKit does.
private func lookup(_ v: BcachefsVolume, _ path: String) async throws -> BcachefsItem {
    var item: FSItem = try v.rootItem()
    for part in path.split(separator: "/") {
        item = try await v.lookupItem(named: FSFileName(string: String(part)), inDirectory: item).0
    }
    return item as! BcachefsItem
}

private func contents(_ v: BcachefsVolume, _ item: BcachefsItem) throws -> [UInt8] {
    var out: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = try chunk.withUnsafeMutableBytes {
            try v.readBytes(from: item, at: off_t(out.count), into: $0)
        }
        if n == 0 { return out }
        out += chunk.prefix(n)
    }
}

private func sha256(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

private func code(_ body: () async throws -> Void) async -> POSIXErrorCode? {
    do { try await body(); return nil }
    catch let e as POSIXError { return e.code }
    catch { return nil }
}

private func name(_ s: String) -> FSFileName { FSFileName(string: s) }

// MARK: - Reading the reference kernel module's image

@Suite("bcachefs volume over the driver: reading")
struct BcachefsImageReadingTests {

    @Test func everyEntryReadsAsTheReferenceKernelModuleListedIt() async throws {
        let image = try Fixture.image("kernel")
        defer { Fixture.discard(image) }
        let m = try mount(image, writable: false)
        let subvolumes = try rootSubvolumes()
        var checked = 0
        for e in try kernelManifest() {
            let top = String(e.path.split(separator: "/").first ?? "")
            if subvolumes.contains(top) { continue }
            let item = try await lookup(m.volume, e.path)
            let a = try await m.volume.attributes(FSItem.GetAttributesRequest(), of: item)
            #expect(a.fileID.rawValue == e.inode, "\(e.path): inode")
            #expect(a.linkCount == e.linkCount, "\(e.path): link count")
            #expect(a.mode == e.mode, "\(e.path): mode")
            switch e.type {
            case "dir":
                #expect(a.type == .directory, "\(e.path)")
            case "symlink":
                #expect(a.type == .symlink, "\(e.path)")
                let t = try await m.volume.readSymbolicLink(item)
                #expect(t.string == e.target, "\(e.path): target")
            default:
                #expect(a.type == .file, "\(e.path)")
                #expect(a.size == e.size, "\(e.path): size")
                #expect(sha256(try contents(m.volume, item)) == e.sha256, "\(e.path): contents")
            }
            checked += 1
        }
        #expect(checked > 300, "only \(checked) entries")
        m.volume.shutDown()
    }

    @Test func everyDirectoryListsWhatTheMountListed() async throws {
        let image = try Fixture.image("kernel")
        defer { Fixture.discard(image) }
        let m = try mount(image, writable: false)
        let subvolumes = try rootSubvolumes()
        let entries = try kernelManifest()
        var expected: [String: Set<String>] = ["/": subvolumes]
        for e in entries {
            let parts = e.path.split(separator: "/").map(String.init)
            if subvolumes.contains(parts[0]) { continue }
            let parent = parts.count == 1 ? "/" : "/" + parts.dropLast().joined(separator: "/")
            expected[parent, default: []].insert(parts.last!)
            if e.type == "dir" { expected[e.path, default: []] = expected[e.path] ?? [] }
        }
        for (dir, names) in expected {
            let item = dir == "/" ? try m.volume.rootItem() : try await lookup(m.volume, dir)
            var listed: Set<String> = []
            _ = try m.volume.entries(of: item, after: 0, withAttributes: true) {
                listed.insert($0.name.string ?? "?")
                return true
            }
            // lost+found is the formatter's, not the mount's.
            listed.remove("lost+found")
            #expect(listed == names, "\(dir)")
        }
    }

    @Test func hardLinksAreOneFile() async throws {
        let image = try Fixture.image("kernel")
        defer { Fixture.discard(image) }
        let m = try mount(image, writable: false)
        let linked = Dictionary(grouping: try kernelManifest().filter { $0.linkCount > 1 && $0.type == "file" },
                                by: \.inode).filter { $0.value.count > 1 }
        #expect(!linked.isEmpty, "the kernel image has hard links")
        for (inode, names) in linked {
            for e in names {
                let item = try await lookup(m.volume, e.path)
                #expect(item.inode == inode, "\(e.path)")
            }
        }
    }

    @Test func aSubvolumeIsListedButNotEnteredAndSaysSo() async throws {
        let image = try Fixture.image("kernel")
        defer { Fixture.discard(image) }
        let m = try mount(image, writable: false)
        let subvolumes = try rootSubvolumes()
        #expect(!subvolumes.isEmpty)
        let root = try m.volume.rootItem()
        var types: [String: FSItem.ItemType] = [:]
        _ = try m.volume.entries(of: root, after: 0, withAttributes: false) {
            types[$0.name.string ?? "?"] = $0.itemType
            return true
        }
        for sv in subvolumes {
            #expect(types[sv] == .directory, "\(sv)")
            #expect(await code { _ = try await m.volume.lookupItem(named: name(sv), inDirectory: root) } == .ENOTSUP,
                    "the C ABI reads the root subvolume only: \(sv)")
        }
    }

    @Test func aMissingNameIsENOENT() async throws {
        let image = try Fixture.image("kernel")
        defer { Fixture.discard(image) }
        let m = try mount(image, writable: false)
        let root = try m.volume.rootItem()
        #expect(await code { _ = try await m.volume.lookupItem(named: name("no-such-file"), inDirectory: root) } == .ENOENT)
        let file = try await lookup(m.volume, "/hello.txt")
        #expect(await code { _ = try await m.volume.readSymbolicLink(file) } == .EINVAL)
    }

    @Test func extendedAttributesAreTheListersUserNamespace() async throws {
        let image = try Fixture.image("xattr-lengths")
        defer { Fixture.discard(image) }
        let m = try mount(image, writable: false)
        // Each inode's path, from the lister's dirents.
        var parent: [UInt64: (UInt64, String)] = [:]
        for d in listed(try Fixture.text("xattr-lengths.dirents.txt"), type: "dirent") {
            let words = d.rest.split(separator: " ")
            guard words.count >= 3, let ino = UInt64(words[2]) else { continue }
            parent[ino] = (d.inode, String(words[0]))
        }
        func path(_ ino: UInt64) -> String {
            guard let (p, n) = parent[ino] else { return "" }
            return path(p) + "/" + n
        }
        var want: [String: [String: String]] = [:]
        for x in listed(try Fixture.text("xattr-lengths.xattrs.txt"), type: "xattr") {
            let (key, value) = x.rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                .map(String.init).splitPair()
            want[path(x.inode), default: [:]][key] = value
        }
        #expect(want.count >= 5, "\(want.keys)")
        for (p, attrs) in want {
            let item = try await lookup(m.volume, p)
            let names = Set(try await m.volume.xattrs(of: item).compactMap(\.string))
            #expect(names == Set(attrs.keys.map { String($0.dropFirst("user.".count)) }), "\(p)")
            for (key, value) in attrs {
                let got = try await m.volume.xattr(named: name(String(key.dropFirst("user.".count))), of: item)
                #expect(got == Data(value.utf8), "\(p) \(key)")
            }
        }
    }

    @Test func statfsIsTheDevicesBucketsAndFreeSpace() throws {
        let image = try Fixture.image("base")
        defer { Fixture.discard(image) }
        let m = try mount(image, writable: false)
        let report = try Fixture.text("base.super.txt")
        func field(_ key: String) -> String? {
            report.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + ":") }
                .map { $0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces) }
        }
        /// "32.0k" / "512" -> bytes, as the printer writes sizes.
        func bytes(_ text: String?) -> UInt64 {
            guard let text, let last = text.last else { return 0 }
            let scale: Double = last == "k" ? 1024 : last == "M" ? 1_048_576 : 1
            let number = scale == 1 ? text : String(text.dropLast())
            return UInt64(((Double(number) ?? 0) * scale).rounded())
        }
        let buckets = UInt64(field("Buckets") ?? "") ?? 0
        let first = UInt64(field("First bucket") ?? "") ?? 0
        let bucket = bytes(field("Bucket size"))
        let block = bytes(field("block_size"))
        let s = m.volume.volumeStatistics
        #expect(buckets > 0 && bucket > 0 && block > 0)
        #expect(UInt64(s.blockSize) == block)
        #expect(s.totalBlocks == (buckets - first) * bucket / block)
        #expect(s.freeBlocks > 0 && s.freeBlocks < s.totalBlocks)
        #expect(s.availableBlocks == 0, "a read-only mount offers nothing to allocate")
    }

    @Test func theProbeKnowsABcachefsSuperblockAndNothingElse() throws {
        func head(_ set: String) throws -> [UInt8] {
            let image = try Fixture.image(set)
            defer { Fixture.discard(image) }
            return try [UInt8](FileHandle(forReadingFrom: image).read(upToCount: 8192) ?? Data())
        }
        for set in ["kernel", "xattr-lengths", "base"] {
            #expect(BcachefsSuperblock(device: try head(set)) != nil, "\(set)")
        }
        let base = try head("base")
        let sb = try #require(BcachefsSuperblock(device: base))
        let report = try Fixture.text("base.super.txt")
        let external = report.split(separator: "\n").first { $0.hasPrefix("External UUID:") }!
            .split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
        #expect(sb.containerUUID == UUID(uuidString: external), "the reference's External UUID")
        #expect(sb.label.isEmpty, "the reference printed Label: (none)")
        var flipped = base
        flipped[4096 + 0x18] ^= 0xFF
        #expect(BcachefsSuperblock(device: flipped) == nil)
        #expect(BcachefsSuperblock(device: [UInt8](repeating: 0, count: 8192)) == nil)
        #expect(BcachefsSuperblock(device: Array(base.prefix(4096 + 0x40))) == nil, "too short")
        // Another filesystem's bytes: an ext4-style superblock magic at 1080
        // and nothing at bcachefs's place.
        var ext4 = [UInt8](repeating: 0, count: 8192)
        ext4[1080] = 0x53; ext4[1081] = 0xEF
        #expect(BcachefsSuperblock(device: ext4) == nil)
    }
}

// MARK: - Writing the write study's base

@Suite("bcachefs volume over the driver: writing")
struct BcachefsImageWritingTests {

    /// The image's state as the driver's own C ABI reads it on a fresh
    /// handle: stat, contents, link target, xattrs.
    final class Reader {
        let fs: OpaquePointer
        init(_ image: URL) throws {
            guard let fs = fs_bcachefs_mount(image.path) else { throw POSIXError(.EIO) }
            self.fs = fs
        }
        deinit { fs_bcachefs_umount(fs) }

        func stat(_ path: String) -> fs_bcachefs_attr_t? {
            var a = fs_bcachefs_attr_t()
            return fs_bcachefs_stat(fs, path, &a) == 0 ? a : nil
        }
        func bytes(_ path: String) -> [UInt8]? {
            guard let a = stat(path) else { return nil }
            var buf = [UInt8](repeating: 0, count: Int(a.size))
            let n = buf.withUnsafeMutableBytes { fs_bcachefs_read_file(fs, path, $0.baseAddress, 0, a.size) }
            return n == Int64(a.size) ? buf : nil
        }
        func target(_ path: String) -> String? {
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = buf.withUnsafeMutableBytes { fs_bcachefs_readlink(fs, path, $0.baseAddress, 4096) }
            return n >= 0 ? String(decoding: buf.prefix(Int(n)), as: UTF8.self) : nil
        }
        func xattr(_ path: String, _ name: String) -> String? {
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = buf.withUnsafeMutableBytes { fs_bcachefs_getxattr(fs, path, name, $0.baseAddress, 4096) }
            return n >= 0 ? String(decoding: buf.prefix(Int(n)), as: UTF8.self) : nil
        }
    }

    @Test func everyWriteOperationLandsAsTheDriverReadsItBack() async throws {
        let image = try Fixture.image("base")
        defer { Fixture.discard(image) }
        let m = try mount(image, writable: true)
        let v = m.volume
        #expect(v.allowsWrites)
        let d = try await lookup(v, "/d")

        // A file, written in three calls: the start, an append, and one
        // byte in the middle.
        let (f, _) = try await v.createItem(named: name("new.txt"), type: .file, inDirectory: d,
                                            attributes: FSItem.SetAttributesRequest())
        #expect(try await v.write(contents: Data("hello".utf8), to: f, at: 0) == 5)
        #expect(try await v.write(contents: Data(" world".utf8), to: f, at: 5) == 6)
        #expect(try await v.write(contents: Data("J".utf8), to: f, at: 0) == 1)
        // Read back through the volume, after the writes, too.
        #expect(try contents(v, f as! BcachefsItem) == Array("Jello world".utf8))

        // Sizes: shrunk, then grown with zeros.
        let (g, _) = try await v.createItem(named: name("sized"), type: .file, inDirectory: d,
                                            attributes: FSItem.SetAttributesRequest())
        _ = try await v.write(contents: Data("abcdef".utf8), to: g, at: 0)
        let shrink = FSItem.SetAttributesRequest(); shrink.size = 3
        _ = try await v.setAttributes(shrink, on: g)
        let grow = FSItem.SetAttributesRequest(); grow.size = 6
        _ = try await v.setAttributes(grow, on: g)

        // A large file, in extents rather than inline.
        let big = (0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        let (h, _) = try await v.createItem(named: name("big.bin"), type: .file, inDirectory: d,
                                            attributes: FSItem.SetAttributesRequest())
        _ = try await v.write(contents: Data(big), to: h, at: 0)

        // Directories, a move across them, a rename over an existing file.
        let (sub, _) = try await v.createItem(named: name("sub"), type: .directory, inDirectory: d,
                                              attributes: { let r = FSItem.SetAttributesRequest(); r.mode = 0o750; return r }())
        _ = try await v.renameItem(f, inDirectory: d, named: name("new.txt"),
                                   to: name("moved.txt"), inDirectory: sub, overItem: nil)
        let (r, _) = try await v.createItem(named: name("replacement"), type: .file, inDirectory: d,
                                            attributes: FSItem.SetAttributesRequest())
        _ = try await v.write(contents: Data("replaced\n".utf8), to: r, at: 0)
        _ = try await v.renameItem(r, inDirectory: d, named: name("replacement"),
                                   to: name("existing"), inDirectory: d, overItem: nil)
        let (gone, _) = try await v.createItem(named: name("empty-dir"), type: .directory, inDirectory: d,
                                               attributes: FSItem.SetAttributesRequest())
        try await v.removeItem(gone, named: name("empty-dir"), fromDirectory: d)

        // Links: a symlink, and a hard link that is then the only name.
        let moved = try await lookup(v, "/d/sub/moved.txt")
        _ = try await v.createSymbolicLink(named: name("link"), inDirectory: d,
                                           attributes: FSItem.SetAttributesRequest(),
                                           linkContents: name("sub/moved.txt"))
        _ = try await v.createLink(to: moved, named: name("hard"), inDirectory: d)
        let (doomed, _) = try await v.createItem(named: name("doomed"), type: .file, inDirectory: d,
                                                 attributes: FSItem.SetAttributesRequest())
        try await v.removeItem(doomed, named: name("doomed"), fromDirectory: d)

        // Mode, owner, extended attributes.
        let attrs = FSItem.SetAttributesRequest()
        attrs.mode = 0o600; attrs.uid = 1000; attrs.gid = 1001
        let after = try await v.setAttributes(attrs, on: moved)
        #expect(after.mode == 0o600 && after.uid == 1000 && after.gid == 1001)
        try await v.setXattr(named: name("colour"), to: Data("blue".utf8), on: moved, policy: .mustCreate)
        try await v.setXattr(named: name("gone"), to: Data("x".utf8), on: moved, policy: .alwaysSet)
        try await v.setXattr(named: name("gone"), to: nil, on: moved, policy: .delete)
        #expect(try await v.xattrs(of: moved).compactMap(\.string) == ["colour"])
        v.shutDown()

        // What the driver reads on a handle of its own.
        let rd = try Reader(image)
        #expect(rd.bytes("/d/sub/moved.txt") == Array("Jello world".utf8))
        #expect(rd.bytes("/d/sized") == [0x61, 0x62, 0x63, 0, 0, 0])
        #expect(rd.bytes("/d/big.bin") == big)
        #expect(rd.bytes("/d/existing") == Array("replaced\n".utf8))
        #expect(rd.stat("/d/sub").map { $0.mode & 0o7777 } == 0o750)
        #expect(rd.stat("/d/sub").map { $0.mode & 0o170000 } == 0o040000)
        #expect(rd.stat("/d/new.txt") == nil && rd.stat("/d/replacement") == nil)
        #expect(rd.stat("/d/empty-dir") == nil && rd.stat("/d/doomed") == nil)
        #expect(rd.target("/d/link") == "sub/moved.txt")
        let a = try #require(rd.stat("/d/sub/moved.txt"))
        #expect((a.mode & 0o7777, a.uid, a.gid, a.nlink) == (0o600, 1000, 1001, 2))
        #expect(rd.stat("/d/hard")?.ino == a.ino)
        #expect(rd.xattr("/d/sub/moved.txt", "user.colour") == "blue")
        #expect(rd.xattr("/d/sub/moved.txt", "user.gone") == nil)
    }

    @Test func theDriversRefusalsReachFSKitAsTheirErrno() async throws {
        let image = try Fixture.image("base")
        defer { Fixture.discard(image) }
        let m = try mount(image, writable: true)
        let v = m.volume
        let root = try v.rootItem()
        let d = try await lookup(v, "/d")
        #expect(await code { try await v.removeItem(d, named: name("d"), fromDirectory: root) } == .ENOTEMPTY)
        #expect(await code { _ = try await v.createItem(named: name("existing"), type: .file, inDirectory: d, attributes: FSItem.SetAttributesRequest()) } == .EEXIST)
        let missing = BcachefsItem(inode: 1, volumePath: "/d/missing", parentInode: d.inode)
        #expect(await code { try await v.removeItem(missing, named: name("missing"), fromDirectory: d) } == .ENOENT)
        let existing = try await lookup(v, "/d/existing")
        #expect(await code { try await v.setXattr(named: name("x"), to: nil, on: existing, policy: .delete) } == .ENOATTR)
        #expect(await code { _ = try await v.xattr(named: name("x"), of: existing) } == .ENOATTR)
    }

    @Test func freeSpaceFallsAsDataIsWritten() async throws {
        let image = try Fixture.image("base")
        defer { Fixture.discard(image) }
        let m = try mount(image, writable: true)
        let v = m.volume
        let before = v.volumeStatistics
        #expect(before.availableBlocks == before.freeBlocks && before.freeBlocks > 0)
        let d = try await lookup(v, "/d")
        let (f, _) = try await v.createItem(named: name("fill"), type: .file, inDirectory: d,
                                            attributes: FSItem.SetAttributesRequest())
        _ = try await v.write(contents: Data(count: 1 << 20), to: f, at: 0)
        let after = v.volumeStatistics
        let used = (before.freeBlocks - after.freeBlocks) * UInt64(after.blockSize)
        #expect(used >= 1 << 20, "1 MiB written, \(used) bytes taken")
    }

    @Test func aReadOnlyMountChangesNothing() async throws {
        let image = try Fixture.image("base")
        defer { Fixture.discard(image) }
        let before = try Data(contentsOf: image)
        let m = try mount(image, writable: true, policy: .readOnly)
        let d = try await lookup(m.volume, "/d")
        #expect(await code { _ = try await m.volume.createItem(named: name("x"), type: .file, inDirectory: d, attributes: FSItem.SetAttributesRequest()) } == .EROFS)
        m.volume.shutDown()
        #expect(try Data(contentsOf: image) == before)
    }

    @Test func aWriteHandleTheDriverRefusesIsEveryWritesErrno() async throws {
        let image = try Fixture.image("base")
        defer { Fixture.discard(image) }
        // A device that cannot be written: the driver refuses the write
        // handle with EROFS, the mount still reads, and writes say why.
        let device = try #require(fs_core_file_open(image.path, false))
        let driver = try BcachefsDriver(device: device, writable: true)
        #expect(driver.writeRefusal == EROFS)
        let v = BcachefsVolume(volumeID: FSVolume.Identifier(uuid: UUID()),
                               volumeName: FSFileName(string: "test"), backend: driver,
                               policy: .readWrite, bsdName: "disk9s1",
                               stats: IOStatsCollector(label: "test", emit: { _ in }))
        let d = try await lookup(v, "/d")
        #expect(await code { _ = try await v.createItem(named: name("x"), type: .file, inDirectory: d, attributes: FSItem.SetAttributesRequest()) } == .EROFS)
        let existing = try await lookup(v, "/d/existing")
        #expect(try contents(v, existing).count > 0)
        v.shutDown()
    }
}

private extension Array where Element == String {
    /// The two halves of a `name:value` split.
    func splitPair() -> (String, String) {
        (self[0], count > 1 ? self[1] : "")
    }
}
