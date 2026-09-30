//
// AgentAuthority.swift — what the agent checks before it attaches or
// detaches a disk image on its caller's behalf (diskjockey#94).
//
// The agent is unsandboxed and the app is not, so every request is a
// question of whether the app could have done the thing itself. The
// connection's code-signing requirement (main.swift) proves the caller is
// our app; it does not prove the app is entitled to the particular file or
// device it names. Two checks close that:
//
//   * ATTACH carries proof of read access. The app opens the image and
//     sends the open file over XPC with the request. Its sandbox either
//     allowed that open or it did not, and the agent confirms the file it
//     received is the image at the path by device and inode. A bug in the
//     app that names a path its sandbox never granted has nothing to send.
//
//   * DETACH is refused for any device this agent did not attach. The
//     agent records what each attach produced, and a detach must name a
//     device hdiutil currently reports as attached FROM THE SAME IMAGE the
//     record names. That second half matters because BSD numbers are
//     reused: /dev/disk12 after its image is ejected may be a USB drive or
//     somebody else's image, and a record of the number alone would hand
//     it over.
//
// The record is persisted (`AttachLedgerFile`) because launchd restarts
// this agent whenever it likes, and an image attached before a restart
// still has to be detachable after one.
//
// Kept free of Process and XPC so `swift test` can reach it: Package.swift
// builds this file alone as DiskJockeyAgentCore.
//

import Foundation
import Darwin

// `Result<_, String>` uses a plain string as the lightweight failure value.
// `@retroactive` acknowledges this conformance is on a type we do not own
// (SE-0364) and silences the Swift 6 retroactive-conformance warning.
extension String: @retroactive Error {}

/// One attached disk image as `hdiutil` reports it.
struct AttachedImage: Codable, Equatable, Sendable {
    let imagePath: String
    let imageAlias: String
    let devices: [String]

    init(imagePath: String, imageAlias: String = "", devices: [String]) {
        self.imagePath = imagePath
        self.imageAlias = imageAlias
        self.devices = devices
    }

    /// Whether this is the image at `path`, compared canonically.
    func isImage(at path: String) -> Bool {
        let want = AgentAuthority.canonical(path)
        if AgentAuthority.canonical(imagePath) == want { return true }
        return !imageAlias.isEmpty && AgentAuthority.canonical(imageAlias) == want
    }
}

/// The two `hdiutil -plist` outputs the agent reads.
enum HdiutilPlist {
    /// `hdiutil info -plist`: every image attached on the machine.
    static func images(fromInfo data: Data) -> [AttachedImage]? {
        guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }
        return images.map { image in
            AttachedImage(imagePath: (image["image-path"] as? String) ?? "",
                          imageAlias: (image["image-alias"] as? String) ?? "",
                          devices: devEntries(image["system-entities"]))
        }
    }

    /// `hdiutil attach -plist`: the device nodes one attach produced.
    static func devices(fromAttach data: Data) -> [String]? {
        guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              plist["system-entities"] is [[String: Any]] else { return nil }
        return devEntries(plist["system-entities"])
    }

    private static func devEntries(_ entities: Any?) -> [String] {
        ((entities as? [[String: Any]]) ?? []).compactMap { $0["dev-entry"] as? String }
    }
}

enum AgentAuthority {
    /// A BSD disk name, and nothing else. Anchored at both ends: an
    /// unanchored match would accept `/dev/disk1 ; anything`.
    static func isBSDDiskName(_ name: String) -> Bool {
        name.range(of: #"^/dev/disk\d+(s\d+)?$"#, options: .regularExpression) != nil
    }

    /// `/dev/disk5s1` → `/dev/disk5`; a whole disk is its own.
    static func wholeDisk(of name: String) -> String? {
        guard isBSDDiskName(name) else { return nil }
        guard let r = name.range(of: #"s\d+$"#, options: .regularExpression) else { return name }
        return String(name[..<r.lowerBound])
    }

    /// A path with its symlinks resolved. hdiutil's non-file image paths
    /// (`ram://…`) are left as they are.
    static func canonical(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Whether `path` is an image this agent will attach, given `proof`: a
    /// file descriptor the caller opened and sent with the request.
    ///
    /// Symlinks are resolved first, then the path must be an existing
    /// regular file, and `proof` must be open for reading on that same
    /// file — same device, same inode. Resolving BEFORE checking is the
    /// order that matters; a symlink checked and then followed is the
    /// classic race.
    static func attachableImage(_ path: String, proof: Int32) -> Result<String, String> {
        let resolved = canonical(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
            return .failure("no such file: \(path)")
        }
        guard !isDirectory.boolValue else {
            return .failure("not a disk image: \(path) is a directory")
        }
        var onDisk = stat()
        guard stat(resolved, &onDisk) == 0 else {
            return .failure("cannot stat \(path): \(String(cString: strerror(errno)))")
        }
        var sent = stat()
        let flags = fcntl(proof, F_GETFL)
        guard flags >= 0, fstat(proof, &sent) == 0 else {
            return .failure("refusing to attach \(path): the request carried no open file to show the caller may read it")
        }
        guard (flags & O_ACCMODE) != O_WRONLY else {
            return .failure("refusing to attach \(path): the caller's file is open for writing only, which shows nothing about reading it")
        }
        guard (sent.st_mode & S_IFMT) == S_IFREG,
              sent.st_dev == onDisk.st_dev, sent.st_ino == onDisk.st_ino else {
            return .failure("refusing to attach \(path): the file the caller opened is not that image, so nothing shows the caller may read it")
        }
        return .success(resolved)
    }
}

/// The images this agent attached, and the check a detach has to pass.
struct AttachLedger: Codable, Equatable, Sendable {
    private(set) var images: [AttachedImage] = []

    /// Record an attach of `imagePath` that produced `devices`. Replaces
    /// any record for the same image or overlapping devices, which can
    /// only be stale.
    mutating func recordAttach(imagePath: String, devices: [String]) {
        let path = AgentAuthority.canonical(imagePath)
        let nodes = Set(devices)
        images.removeAll { $0.isImage(at: path) || !nodes.isDisjoint(with: $0.devices) }
        images.append(AttachedImage(imagePath: path, devices: devices))
    }

    /// Forget the attach `device` belongs to, once it has been detached.
    mutating func forget(device: String) {
        guard let whole = AgentAuthority.wholeDisk(of: device) else { return }
        images.removeAll { $0.devices.contains(whole) || $0.devices.contains(device) }
    }

    /// Drop every record hdiutil no longer shows attached from its image:
    /// ejected in Finder, detached by another tool, or lost to a reboot.
    mutating func prune(attached current: [AttachedImage]) {
        images.removeAll { record in
            !current.contains { live in
                live.isImage(at: record.imagePath)
                    && !Set(live.devices).isDisjoint(with: record.devices)
            }
        }
    }

    /// Whether `bsdName` may be detached, given what hdiutil reports
    /// attached right now.
    func authorizeDetach(_ bsdName: String, attached current: [AttachedImage]) -> Result<Void, String> {
        guard let whole = AgentAuthority.wholeDisk(of: bsdName) else {
            return .failure("refusing to detach \(bsdName): not a BSD disk name")
        }
        guard let live = current.first(where: { $0.devices.contains(bsdName) }) else {
            return .failure("refusing to detach \(bsdName): it is not an attached disk image")
        }
        let ours = images.contains { record in
            (record.devices.contains(bsdName) || record.devices.contains(whole))
                && live.isImage(at: record.imagePath)
        }
        guard ours else {
            return .failure("refusing to detach \(bsdName): this agent did not attach it")
        }
        return .success(())
    }
}

/// `AttachLedger` persisted as JSON, shared by every connection.
///
/// An unreadable file reads as an empty ledger, so the failure is a refused
/// detach the user sees, never a detach of something unrecorded.
final class AttachLedgerFile: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/com.antimatterstudios.diskjockey.agent/attached-images.json`.
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.antimatterstudios.diskjockey.agent", isDirectory: true)
            .appendingPathComponent("attached-images.json")
    }

    /// Read the ledger, let `body` change it, and write it back if it did.
    func update<T>(_ body: (inout AttachLedger) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        var ledger = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(AttachLedger.self, from: $0) } ?? AttachLedger()
        let before = ledger
        let result = body(&ledger)
        if ledger != before {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(ledger).write(to: url, options: .atomic)
            } catch {
                NSLog("[AttachLedger] could not write %@: %@", url.path, "\(error)")
            }
        }
        return result
    }
}
