//
// AgentAuthority.swift — the checks the agent makes before it attaches or
// detaches a disk image on its caller's behalf, and the hdiutil output they
// read.
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

    /// Whether `path` is an image this agent will attach. `proof` is not
    /// consulted yet.
    ///
    /// Resolve symlinks first, then require a regular file that exists.
    /// Resolving BEFORE checking is the order that matters; a symlink
    /// checked and then followed is the classic race.
    static func attachableImage(_ path: String, proof: Int32) -> Result<String, String> {
        let resolved = canonical(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
            return .failure("no such file: \(path)")
        }
        guard !isDirectory.boolValue else {
            return .failure("not a disk image: \(path) is a directory")
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

    /// Whether `bsdName` may be detached. Only its shape is checked yet.
    func authorizeDetach(_ bsdName: String, attached current: [AttachedImage]) -> Result<Void, String> {
        guard AgentAuthority.isBSDDiskName(bsdName) else {
            return .failure("refusing to detach \(bsdName): not a BSD disk name")
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
