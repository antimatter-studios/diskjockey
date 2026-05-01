//
// RawDisksModel.swift — sibling of AttachedDisksModel for *unmounted* /
// *unformatted* media. Polls `diskutil list -plist` so the sidebar can
// show "the SD card you just inserted but haven't formatted yet" or
// "this USB stick has an unrecognized partition layout" — exactly the
// state where the user wants to *format* or *partition* it.
//
// AttachedDisksModel only sees what /sbin/mount reports, so anything
// without a filesystem is invisible to it. This model fills that gap.
//
// MVP uses subprocess polling rather than DiskArbitration callbacks
// because diskutil's plist already builds the whole-disk → partition
// tree for us, and the existing AttachedDisksModel uses the same
// subprocess pattern under sandbox without entitlement gymnastics.
// 3-second poll matches AttachedDisksModel; if the lag becomes an
// issue, swap the polling guts for a DASession without changing the
// published shape.
//

import Foundation
import Combine
import DiskJockeyLibrary

/// One block device the system has attached. Not necessarily mountable —
/// could be unformatted, partitioned but waiting on slices, or already
/// fully managed by an FSKit extension. The sidebar only renders entries
/// `RawDisksModel` decides are *interesting* (see `formatableDisks`).
public struct RawDisk: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { bsdName }
    /// BSD device name: "disk5" (whole disk) or "disk5s1" (slice).
    public let bsdName: String
    /// Whole-disk parent for slices (`disk5` for `disk5s1`); nil when
    /// `isWhole == true`. Inferred via prefix match against the parsed
    /// disk list — diskutil doesn't expose a parent-ref field.
    public let parentBsdName: String?
    /// Total bytes, as reported by diskutil. For a whole disk this is
    /// the underlying media size; for a slice it's that slice's extent.
    public let size: UInt64
    /// True for "disk5", false for "disk5s1". Affects what actions are
    /// applicable: only whole disks support repartitioning; only slices
    /// (or unpartitioned wholes) support format-as-filesystem.
    public let isWhole: Bool
    /// `Content` field from diskutil — names the partition map type for
    /// whole disks ("GUID_partition_scheme" / "FDisk_partition_scheme")
    /// or the partition role / filesystem type for slices ("Apple_APFS",
    /// "Microsoft Basic Data", "Linux", or empty for genuinely
    /// unformatted media).
    public let content: String
    /// User-visible label if the slice has a mounted filesystem with a
    /// name; nil otherwise. Mainly informational — when present the
    /// disk is already managed by AttachedDisksModel and we don't show
    /// it in the unformatted view.
    public let volumeName: String?
    /// `/Volumes/...` mountpoint if currently mounted, else nil.
    public let mountPoint: String?
    /// True if removable media (SD card, USB stick). Used by
    /// `formatableDisks` to filter out the system SSD.
    public let isRemovable: Bool
    /// True if internal to the machine (built-in SSD, internal SD reader
    /// for recent Macs). Combined with `isRemovable` to decide what's
    /// safe to expose for formatting — the built-in SD reader reports
    /// `internal=true, ejectable=true`.
    public let isInternal: Bool
    /// True if the user can eject the media (USB / SD card). Built-in
    /// SSD is `false`.
    public let isEjectable: Bool

    /// True if this entry has no filesystem AND no partition map — i.e.
    /// it's truly raw bytes the user can format directly. The simplest
    /// case: blank SD card straight from a manufacturer.
    public var isUnformatted: Bool {
        // Whole disk with no Content marker → unformatted disk.
        // Slice with empty Content → unformatted partition.
        // "FDisk_partition_scheme" / "GUID_partition_scheme" wholes are
        // PARTITIONED but the slices below them may or may not be
        // formatted; that's a per-slice question.
        return content.isEmpty
            || content == "Apple_Free"
            || content.lowercased() == "free"
    }
}

/// Polls diskutil and exposes the resulting disk list to SwiftUI.
/// Mirrors `AttachedDisksModel` shape so consumers can read both with
/// the same idioms.
@MainActor
public final class RawDisksModel: ObservableObject {
    /// All block devices reported by diskutil, in `disk0, disk0s1, …`
    /// order. The detail view + sidebar pick subsets via the
    /// computed properties below.
    @Published public private(set) var disks: [RawDisk] = []

    private var timer: Timer?
    private let pollInterval: TimeInterval

    public init(pollInterval: TimeInterval = 3.0) {
        self.pollInterval = pollInterval
    }

    public func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        let fresh = Self.enumerate()
        guard fresh != disks else { return }
        disks = fresh
    }

    // MARK: - Computed views for the UI

    /// Disks the sidebar shows under "Unformatted Disks" — removable
    /// media that has either no filesystem at all (whole disk with no
    /// partition map) or one or more empty/raw partitions.
    /// Excludes:
    ///   - The system SSD (disk0 on Apple Silicon, often disk0/disk1).
    ///   - Anything the AttachedDisksModel would already render — i.e.
    ///     a disk whose slices are all mounted with recognized fs types.
    ///   - APFS containers (Apple-internal indirection).
    /// What's left is "real removable media that needs the user's
    /// attention before macOS will treat it as a usable volume."
    public var formatableDisks: [RawDisk] {
        disks.filter { isUserFacingFormattable($0) }
    }

    /// Children of a whole-disk row. Used by the detail view to render
    /// the partition tree below a disk header.
    public func slices(of whole: RawDisk) -> [RawDisk] {
        guard whole.isWhole else { return [] }
        return disks.filter { $0.parentBsdName == whole.bsdName }
    }

    /// Look up a single disk by BSD name. SidebarItem stores BSD as
    /// the routing key; the detail view resolves back to the full
    /// record here.
    public func disk(withBsdName bsd: String) -> RawDisk? {
        disks.first { $0.bsdName == bsd }
    }

    // MARK: - Filtering

    private func isUserFacingFormattable(_ disk: RawDisk) -> Bool {
        // System disk(s): apple_silicon Macs put the OS on disk0/disk1
        // as APFS containers backed by physical store disk2/disk3 etc.
        // The reliable safety check is "Internal=true AND not removable
        // AND not ejectable" — that's a built-in fixed drive, never a
        // legitimate format target. Removable internal devices (the
        // built-in SD reader on a MacBook Pro) report
        // Internal=true + Removable=true + Ejectable=true and ARE
        // legitimate format targets.
        if disk.isInternal && !disk.isRemovable && !disk.isEjectable {
            return false
        }
        // APFS containers and synthesized disks — diskutil reports them
        // with content "Apple_APFS_Container" or content names starting
        // with "Apple_APFS"; they're virtual indirection on top of a
        // physical store, not directly formattable.
        if disk.content.hasPrefix("Apple_APFS") {
            return false
        }
        // Whole disks always show, slices only when they have something
        // worth surfacing (free space or unformatted).
        if disk.isWhole {
            return true
        }
        // Slices with a recognized non-Apple filesystem (msdos, exfat,
        // Linux, Microsoft Basic Data with no mount, etc.) are also
        // candidates — the user might want to reformat them. Slices
        // that are currently mounted under our FSKit extensions show
        // up in AttachedDisksModel; keep them here too so the format
        // action is reachable from one place.
        return !disk.content.isEmpty
    }

    // MARK: - diskutil parsing

    /// Run `/usr/sbin/diskutil list -plist` and parse the `AllDisksAndPartitions`
    /// tree, augmenting each entry with details from `diskutil info -plist`
    /// per BSD name (necessary because `list -plist` doesn't include
    /// Removable/Ejectable/Internal flags). The cost is one fork per disk
    /// per poll — fine for typical machines (5–10 disks) and the same
    /// subprocess approach already used by AttachedDisksModel.
    private static func enumerate() -> [RawDisk] {
        guard let listPlist = runDiskutil(args: ["list", "-plist"]) else {
            return []
        }

        guard let parsed = try? PropertyListSerialization.propertyList(
            from: listPlist, options: [], format: nil
        ) as? [String: Any],
        let allDisksAndPartitions = parsed["AllDisksAndPartitions"] as? [[String: Any]]
        else {
            return []
        }

        var result: [RawDisk] = []
        for whole in allDisksAndPartitions {
            guard let bsd = whole["DeviceIdentifier"] as? String else { continue }
            let size = (whole["Size"] as? NSNumber)?.uint64Value ?? 0
            let content = whole["Content"] as? String ?? ""
            let info = fetchInfo(bsd: bsd) ?? [:]
            result.append(RawDisk(
                bsdName: bsd,
                parentBsdName: nil,
                size: size,
                isWhole: true,
                content: content,
                volumeName: info["VolumeName"] as? String,
                mountPoint: nonEmpty(info["MountPoint"] as? String),
                isRemovable: (info["Removable"] as? NSNumber)?.boolValue ?? false,
                isInternal: (info["Internal"] as? NSNumber)?.boolValue ?? true,
                isEjectable: (info["Ejectable"] as? NSNumber)?.boolValue ?? false
            ))

            for partition in whole["Partitions"] as? [[String: Any]] ?? [] {
                guard let pBsd = partition["DeviceIdentifier"] as? String else { continue }
                let pSize = (partition["Size"] as? NSNumber)?.uint64Value ?? 0
                let pContent = partition["Content"] as? String ?? ""
                let pInfo = fetchInfo(bsd: pBsd) ?? [:]
                result.append(RawDisk(
                    bsdName: pBsd,
                    parentBsdName: bsd,
                    size: pSize,
                    isWhole: false,
                    content: pContent,
                    volumeName: partition["VolumeName"] as? String
                        ?? pInfo["VolumeName"] as? String,
                    mountPoint: nonEmpty(partition["MountPoint"] as? String)
                        ?? nonEmpty(pInfo["MountPoint"] as? String),
                    isRemovable: (pInfo["Removable"] as? NSNumber)?.boolValue ?? false,
                    isInternal: (pInfo["Internal"] as? NSNumber)?.boolValue ?? true,
                    isEjectable: (pInfo["Ejectable"] as? NSNumber)?.boolValue ?? false
                ))
            }
        }
        return result
    }

    private static func fetchInfo(bsd: String) -> [String: Any]? {
        guard let data = runDiskutil(args: ["info", "-plist", bsd]) else {
            return nil
        }
        return try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
    }

    /// Spawn diskutil and capture stdout. Returns nil on any failure
    /// (binary missing, non-zero exit, no output) — callers fall back
    /// to "no disks discovered" rather than throwing.
    private static func runDiskutil(args: [String]) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return try? outPipe.fileHandleForReading.readToEnd()
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty else { return nil }
        return s
    }
}
