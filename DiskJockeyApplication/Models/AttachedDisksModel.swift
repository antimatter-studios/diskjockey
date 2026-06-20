//
// AttachedDisksModel.swift — enumerates filesystems that the system has
// already mounted (ext4 / ntfs / other FSKit-managed types) so they can
// appear in the sidebar for visibility. These are NOT user-configured
// mounts; they're whatever is currently attached + mounted by the kernel
// (hdiutil attach + auto-probe, SD card plug-in, FSKit extensions, etc).
//

import Foundation
import Combine
import DiskJockeyLibrary

/// Live fsck status for a volume. Drives the detail-pane status row +
/// progress bar. Updated in response to kind-tagged events emitted by
/// our FSKit extensions (`volume.dirty`, `fsck.start`, `fsck.progress`,
/// `fsck.done`, `fsck.failed`).
public enum FsckStatus: Equatable, Hashable {
    case unknown
    case clean
    case dirty
    case running(phase: String, done: UInt64, total: UInt64)
    case completed(dirtyCleared: Bool, logfileBytes: UInt64)
    case failed(String)
}

/// Where this disk sits in its lifecycle. Drives sidebar visual + the
/// conditional third line ("Verifying disk…").
///
///   - `.mounting` — created from extension events (probe / loadResource /
///     fsck.start) but not yet visible in `/sbin/mount`. The preview-row
///     state. macOS auto-probe → loadResource → fsck → mount; the entry
///     gets created on probe so the user sees "something is happening"
///     during the multi-minute fsck window before the path appears.
///   - `.live` — currently in `/sbin/mount`.
///   - `.repairing` — intentionally unmounted by us for an in-flight
///     repair pass. Survives the `/sbin/mount` poll AND DA's
///     "disappeared" event so the user keeps seeing the row (with a
///     "Repairing…" badge + live fsck progress) instead of having
///     the disk silently vanish mid-operation.
///   - `.repairFailed(message)` — terminal state when the unmount /
///     fsck / remount pipeline couldn't finish. Tells the user "the
///     in-app repair couldn't complete; reattach the disk to start
///     fresh" and stays visible until the row is replaced by a real
///     mount-table entry on next replug.
///
/// Disks that drop out of `/sbin/mount` AND aren't in one of the
/// preserved-states above are removed from the sidebar entirely on
/// the next refresh().
public enum AttachedDiskStatus: Equatable, Hashable {
    case mounting
    case live
    case repairing
    case repairFailed(String)
}

public struct AttachedDisk: Identifiable, Equatable, Hashable {
    /// Stable handle for the lifetime of this row, set once at creation
    /// and never changes. Priority at creation:
    ///   1. `stableIdentity` (UUID/serial from volume.info) — survives
    ///      mount/unmount/replug/restart, so the same physical disk
    ///      coalesces back onto the same row.
    ///   2. `"bsd:\(name)"` — survives mount/unmount within a session
    ///      (BSD names are stable until reboot or replug).
    ///   3. `"path:\(mountPath)"` — last-resort fallback for rows
    ///      created from a mount(8) line we can't correlate to a bsd.
    public let id: String
    /// Strongest known identity for this disk. Filled in when a
    /// `volume.info` event arrives carrying `volume_uuid` (ext4) or
    /// `serial_number` (ntfs). Promotes the row to coalesce-by-identity
    /// across replug + app-restart cycles.
    public var stableIdentity: String?
    /// Current BSD name (e.g. "disk5s1"). Filled in from probe/load
    /// events or derived from `devicePath`. May change across replug
    /// cycles for the same physical disk — `stableIdentity` is what
    /// guarantees row continuity in that case.
    public var bsd: String?
    /// e.g. "/Volumes/inline-vol". Empty for `.mounting` preview rows
    /// that haven't reached mount(8) yet.
    public var mountPath: String
    public var devicePath: String            // e.g. "/dev/disk5"
    public var fsType: String                // e.g. "ext4"
    public var name: String                  // user-visible label
    /// Whether the volume is mounted read-write. Derived at parse time
    /// from `/sbin/mount`'s flag list — macOS emits `read-only` (with
    /// hyphen) for RO mounts; some older releases emit the bare token
    /// `ro`, so we accept both. RW is the unsurprising default.
    public var isWritable: Bool
    /// Lifecycle state. See `AttachedDiskStatus`.
    public var status: AttachedDiskStatus = .live
    /// Latest dirty/fsck status for this volume. Keyed into the model
    /// by correlating `fields["bsd"]` (e.g. "disk5") with this disk's
    /// devicePath tail.
    public var fsckStatus: FsckStatus = .unknown
    /// Volume identity/sizing emitted once by the FSKit extension at
    /// mount time (kind="volume.info"). Keys are FS-specific — ext4 has
    /// total_blocks / free_blocks / free_inodes; ntfs has total_clusters
    /// / total_size / ntfs_version. Detail view just iterates + formats.
    public var info: [String: String] = [:]
    /// Recent log lines emitted by the extension for THIS volume (events
    /// whose `fields["bsd"]` matches this disk's BSD). Capped at 500 to
    /// keep memory bounded. Shown in the partition detail view.
    public var partitionLog: [AttachedDiskLogLine] = []
    /// Live I/O metrics fed by the FSKit extension's 1 Hz `io.stats`
    /// event (cumulative counters + a rolling buffer of per-second
    /// throughput samples). Populated whenever an event matching this
    /// disk's BSD arrives; preserved across mount-table polls in
    /// `refresh()`. The detail view's I/O activity section reads
    /// straight from here.
    public var ioStats: IOStats = IOStats()
    /// Latest `repaired_count` from a `fsck.done` event. nil until a
    /// repair pass has actually run.
    public var lastRepairedCount: UInt64? = nil

    /// Latest `anomalies` count from a `fsck.done` event. nil until
    /// the first verify/repair finishes. > 0 after a verify means the
    /// volume has on-disk inconsistencies the user should run repair
    /// against; the detail view surfaces a "Repair recommended" hint
    /// when this is non-zero AND no repair has happened since.
    public var lastAnomaliesFound: UInt64? = nil

    /// Sidebar + detail-header icon. Baseline is the generic external-
    /// drive glyph; when `fsType` names a filesystem that only ships on
    /// one OS family, we overlay an OS-flavored asset (ext* → Linux,
    /// ntfs* → Windows). Keep this list narrow — cross-platform types
    /// (msdos/exfat/apfs/hfs) stay on the baseline because they don't
    /// identify an OS of origin.
    public var icon: PersonalityIcon {
        switch fsType.lowercased() {
        case "ext2", "ext3", "ext4":
            return .asset("tabler-linux-drive")
        case "ntfs", "fsntfs", "ntfs-fskit":
            return .asset("tabler-windows-drive")
        case "erofs", "fserofs", "squashfs", "fssquashfs":
            // Read-only Linux-origin filesystems (EROFS / SquashFS). They
            // ship almost exclusively on Linux media + images, so reuse
            // the Linux-drive glyph rather than the generic external one.
            return .asset("tabler-linux-drive")
        default:
            return .asset("tabler-externaldrive-fill")
        }
    }

    /// Derive the stable id at row-creation time. Priority documented
    /// on `id`. Caller passes whatever it knows; we pick the strongest
    /// and freeze it.
    public static func makeID(stableIdentity: String?, bsd: String?, mountPath: String) -> String {
        if let s = stableIdentity, !s.isEmpty { return "id:\(s)" }
        if let b = bsd, !b.isEmpty { return "bsd:\(b)" }
        return "path:\(mountPath)"
    }

    public init(id: String? = nil,
                stableIdentity: String? = nil,
                bsd: String? = nil,
                mountPath: String,
                devicePath: String,
                fsType: String,
                name: String,
                isWritable: Bool,
                status: AttachedDiskStatus = .live,
                fsckStatus: FsckStatus = .unknown,
                info: [String: String] = [:],
                partitionLog: [AttachedDiskLogLine] = [],
                ioStats: IOStats = IOStats()) {
        self.id = id ?? Self.makeID(stableIdentity: stableIdentity, bsd: bsd, mountPath: mountPath)
        self.stableIdentity = stableIdentity
        self.bsd = bsd
        self.mountPath = mountPath
        self.devicePath = devicePath
        self.fsType = fsType
        self.name = name
        self.isWritable = isWritable
        self.status = status
        self.fsckStatus = fsckStatus
        self.info = info
        self.partitionLog = partitionLog
        self.ioStats = ioStats
    }
}

/// One log line scoped to a specific partition. Subset of AppLogLine —
/// only the fields the detail-view log strip needs.
public struct AttachedDiskLogLine: Identifiable, Equatable, Hashable {
    public let id = UUID()
    public let timestamp: Date
    public let level: String
    public let message: String
    public let source: String
    /// Routing tag carried from the originating `AppLogLine.scope`.
    /// Per-mount detail view filters on this against its own denylist.
    public let scope: String?

    public init(timestamp: Date, level: String, message: String,
                source: String, scope: String? = nil) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.source = source
        self.scope = scope
    }
}

/// NDJSON line in the form the model consumes: timestamp, level,
/// message, source + optional `bsd` resolved from the structured
/// `fields` block (or parsed from the plain-text message as a
/// fallback for legacy lines). LogTailService builds one of these
/// per line.
public struct ParsedLogLine {
    public let timestamp: Date
    public let level: String
    public let source: String
    public let message: String
    /// BSD device name (e.g. "disk6") if the event is tagged with one,
    /// or if the message text obviously refers to one. Routes to
    /// AttachedDisksModel's per-disk log strip.
    public let bsd: String?
    /// FileProvider domain identifier (NSFileProviderDomain.rawValue)
    /// if the event carries `fields["mount"]`. Routes to
    /// DirectMountRegistry's per-mount log strip.
    public let mount: String?
    /// Routing tag carried over from `AppLogLine.scope`.
    public let scope: String?
    public init(timestamp: Date, level: String, source: String,
                message: String, bsd: String?, mount: String? = nil,
                scope: String? = nil) {
        self.timestamp = timestamp
        self.level = level
        self.source = source
        self.message = message
        self.bsd = bsd
        self.mount = mount
        self.scope = scope
    }
}

@MainActor
public final class AttachedDisksModel: ObservableObject {
    /// Disks the model is tracking. Includes:
    ///   - currently in mount(8) (status = .live)
    ///   - extension events have arrived for the BSD but mount(8)
    ///     hasn't caught up (status = .mounting)
    /// A disk that drops out of mount(8) is removed from the array on
    /// the next refresh() — there's no offline roster.
    @Published public private(set) var disks: [AttachedDisk] = []

    /// Scopes the per-mount detail-view log hides. Empty by default —
    /// the per-mount pane is the right place to see the full picture
    /// (enumeration, IO, stats). UI offers toggles to add/remove.
    /// Applies globally across every mount's detail view; per-mount
    /// view is responsible for filtering on read.
    @Published public var suppressedScopes: Set<String> = []

    /// Fstypes we display in the sidebar. By default shows everything
    /// that could realistically be an interesting disk (our own
    /// extensions' outputs + common external filesystems). Override at
    /// runtime if you want to narrow.
    public var fsTypesOfInterest: Set<String> = [
        "ext4",              // DiskJockeyEXT4 / fs-ext4
        "ntfs",              // Apple legacy ntfs.fs
        "fsntfs",            // DiskJockeyNTFS (our FSShortName)
        "ntfs-fskit",        // ext4-fskit project's old ntfsfskitd
        "squashfs",          // DiskJockeySQUASHFS (FSPersonalities name)
        "erofs",             // DiskJockeyEROFS (FSPersonalities name)
        "fserofs",           // DiskJockeyEROFS FSShortName
        "msdos",             // FAT-family
        "exfat",             // Apple's built-in exFAT
    ]

    private var timer: Timer?
    private let pollInterval: TimeInterval
    /// Events that arrived keyed on a BSD we hadn't yet seen in the
    /// mount table (classic race: extension emits volume.info the
    /// instant it mounts, our /sbin/mount poller picks up the mount
    /// 0-3s later). Replayed in refresh() once the disk appears.
    private var pendingEvents: [String: [(kind: String, fields: [String: String])]] = [:]
    /// Same race but for plain log lines (no `kind` — just a message).
    /// Accumulated by BSD until the disk is in `disks`.
    private var pendingLogs: [String: [AttachedDiskLogLine]] = [:]
    private static let logCap = 500

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
        let fresh = MountTableParser.enumerate(fsTypesOfInterest: fsTypesOfInterest)
        var merged: [AttachedDisk] = []
        var consumedIndices: Set<Int> = []  // indices into `disks` we've already merged

        // For each fresh mount(8) entry, find the best-matching existing
        // row and merge state forward (or create a new live row).
        // Cascade: stableIdentity → bsd → mountPath. The first match
        // wins and that prior index is consumed so it isn't carried
        // again. Within a session this is mostly a no-op (mount(8)
        // entries are stable while a disk stays plugged in) — its job
        // is to preserve `.mounting` preview rows' partition log /
        // ioStats / fsckStatus across the transition to `.live`.
        for f in fresh {
            if let idx = matchPriorIndex(for: f, in: disks, excluding: consumedIndices) {
                consumedIndices.insert(idx)
                var copy = disks[idx]
                copy.bsd = f.bsd ?? copy.bsd
                copy.mountPath = f.mountPath
                copy.devicePath = f.devicePath
                copy.fsType = f.fsType
                copy.name = f.name
                copy.isWritable = f.isWritable
                copy.status = .live
                // Overlay statvfs-baseline info onto whatever the
                // extension previously published — extension keys win
                // on conflicts (their values are more authoritative).
                var fresh_info = f.info
                for (k, v) in copy.info { fresh_info[k] = v }
                copy.info = fresh_info
                merged.append(copy)
            } else {
                // First time we've seen this disk this session.
                merged.append(f)
            }
        }

        // Carry forward rows whose status implies "intentionally not
        // in mount(8) right now":
        //   - .mounting    — preview before the kernel publishes
        //   - .repairing   — we unmounted the volume to run fsck
        //   - .repairFailed — terminal state, kept until replug
        // Anything else that didn't match (a prior `.live` row no
        // longer in `/sbin/mount`) is dropped: the disk is unplugged.
        for (i, prior) in disks.enumerated() where !consumedIndices.contains(i) {
            switch prior.status {
            case .mounting, .repairing, .repairFailed:
                merged.append(prior)
            case .live:
                continue
            }
        }

        // Replay queued events / log lines for any row whose bsd is now
        // present. `pendingEvents`/`pendingLogs` cover the launch-time
        // race where LogTailService sees ndjson lines before refresh()
        // builds the disk list. With preview rows we usually catch the
        // events on the live path instead — but the queue is still the
        // safety net.
        for i in merged.indices {
            guard let bsd = merged[i].bsd else { continue }
            if let queued = pendingEvents.removeValue(forKey: bsd) {
                for ev in queued {
                    DiskEventHandler.applyEventInPlace(kind: ev.kind, fields: ev.fields, to: &merged[i])
                }
            }
            if let lines = pendingLogs.removeValue(forKey: bsd) {
                merged[i].partitionLog.append(contentsOf: lines)
                if merged[i].partitionLog.count > Self.logCap {
                    merged[i].partitionLog.removeFirst(merged[i].partitionLog.count - Self.logCap)
                }
            }
        }

        guard merged != disks else { return }

        let oldIDs = Set(disks.map { $0.id })
        for added in merged where !oldIDs.contains(added.id) && added.status == .live {
            AppLog.shared.info("attached: \(added.fsType) at \(added.mountPath) (\(added.devicePath))")
        }
        for (i, prior) in disks.enumerated() where !consumedIndices.contains(i) && prior.status == .live {
            AppLog.shared.info("detached: \(prior.mountPath) (removed from sidebar)")
        }
        disks = merged
    }

    /// Drop every row matching `bsd` from the sidebar immediately,
    /// regardless of what `/sbin/mount` reports. Intended for callers
    /// that have authoritative "this device is gone" information from
    /// outside the mount table (DiskArbitration disappearance, mostly).
    ///
    /// Also fires `diskutil unmount force` against the matching mount
    /// path. The motivation: FSKit extensions whose `unmount` would
    /// have flushed bytes to disk can't actually do so once the device
    /// is gone, so the kernel may keep the mount entry alive as a
    /// zombie. The zombie blocks future mounts on the same path /
    /// device, and `mount(8)` keeps reporting it for minutes (or
    /// indefinitely) until the kernel times the FS out. Forcing the
    /// unmount here cleans the mount table immediately.
    /// Best-effort: if the entry is already gone, diskutil exits
    /// non-zero and we log + move on.
    ///
    /// Why this can't just lean on `refresh()`: polling can't drop
    /// the row until the kernel removes the mount entry, and the
    /// kernel can sit on the zombie indefinitely. We trust the DA
    /// event instead — the disk is physically gone, so the row goes
    /// and the mount table gets nudged.
    public func removeDisk(byBSD bsd: String) {
        let stale = disks.first { $0.bsd == bsd }
        // Repair / repair-failed rows are intentionally off mount(8)
        // for the duration of our own pipeline — DA fires
        // "disappeared" the moment we unmount, but we want to keep
        // the row on screen so the user can see the fsck progress
        // and any subsequent failure state. Skip the row drop AND
        // the force-unmount sweep in those cases.
        if let stale = stale {
            switch stale.status {
            case .repairing, .repairFailed:
                AppLog.shared.info("DA disappearance ignored — bsd=\(bsd) is in \(stale.status) (repair pipeline owns this row)")
                return
            case .live, .mounting:
                break
            }
        }
        let before = disks.count
        disks.removeAll { $0.bsd == bsd }
        pendingEvents.removeValue(forKey: bsd)
        pendingLogs.removeValue(forKey: bsd)
        if disks.count != before {
            AppLog.shared.info("detached: bsd=\(bsd) (DA disappearance — row dropped)")
        }
        // Best-effort cleanup of any lingering mount entry. Run
        // detached so the diskutil call doesn't block this method
        // (which is on the main actor — UI shouldn't wait on a
        // subprocess for an op that's allowed to silently fail).
        if let stale = stale {
            MountTableParser.forceUnmountStale(mountPath: stale.mountPath, bsd: bsd)
        }
    }

    /// Update the lifecycle status of the row matching `id`. Used by
    /// the repair pipeline to flip rows into / out of `.repairing`
    /// while keeping every other field intact.
    public func setStatus(_ status: AttachedDiskStatus, forID id: String) {
        guard let idx = disks.firstIndex(where: { $0.id == id }) else { return }
        disks[idx].status = status
    }

    /// Find the strongest match for a fresh mount(8) row in the existing
    /// `prior` list. Returns the index whose row should absorb `f`.
    /// `excluded` skips indices already claimed by another fresh row in
    /// this same refresh() pass (rare but possible if two fresh rows
    /// hash to the same prior somehow).
    private func matchPriorIndex(for f: AttachedDisk, in prior: [AttachedDisk], excluding excluded: Set<Int>) -> Int? {
        // 1. stable identity (UUID/serial). Strongest signal.
        if let s = f.stableIdentity, !s.isEmpty {
            for (i, p) in prior.enumerated() where !excluded.contains(i) {
                if p.stableIdentity == s { return i }
            }
        }
        // 2. BSD. Survives mount/unmount within a session.
        if let b = f.bsd, !b.isEmpty {
            for (i, p) in prior.enumerated() where !excluded.contains(i) {
                if p.bsd == b { return i }
            }
        }
        // 3. mountPath, for rows that have no bsd (rare — e.g. an
        // extension we didn't probe). Only matches against rows where
        // mountPath is currently set.
        if !f.mountPath.isEmpty {
            for (i, p) in prior.enumerated() where !excluded.contains(i) {
                if p.mountPath == f.mountPath && !p.mountPath.isEmpty { return i }
            }
        }
        return nil
    }

    /// Drop a disk row entirely. Triggered by the user's "Forget"
    /// action — useful for clearing a `.mounting` preview row stuck
    /// in limbo (FSKit extension probed a BSD that never reached
    /// mount(8)). Live rows can be forgotten too but the next refresh()
    /// will resurrect them.
    public func forget(id: String) {
        guard let idx = disks.firstIndex(where: { $0.id == id }) else { return }
        let removed = disks.remove(at: idx)
        AppLog.shared.info("forgot: \(removed.mountPath) (id=\(removed.id))")
    }

    /// Apply a structured event emitted by an FSKit extension via the
    /// NDJSON tail. Match strategy: by `disk.bsd == fields["bsd"]`.
    /// If no row exists for this BSD, create a preview row with
    /// status=.mounting so the user sees the disk in the sidebar
    /// during the multi-minute fsck/mount window before mount(8)
    /// catches up. Routes by kind — dirty/fsck events update
    /// fsckStatus, volume.info populates the info dict that the
    /// detail view renders.
    public func applyExtensionEvent(kind: String, fields: [String: String]) {
        guard let bsd = fields["bsd"] else { return }

        if let idx = disks.firstIndex(where: { $0.bsd == bsd }) {
            DiskEventHandler.applyEventInPlace(kind: kind, fields: fields, to: &disks[idx])
            return
        }

        // Whole-disk BSDs ("disk4") are containers for partitions
        // ("disk4s1", "disk4s2"), not mountable filesystems
        // themselves. An FSKit extension probe against the whole
        // disk would otherwise create a preview row stuck in
        // `.mounting` forever (mount(8) never reports it) that
        // immediately resurrects after Forget. Queue the events
        // instead — the rare no-partition-table case still gets
        // them replayed if a `.live` row materialises via mount(8).
        if MountTableParser.isWholeDiskBSD(bsd) {
            pendingEvents[bsd, default: []].append((kind: kind, fields: fields))
            return
        }

        // No row yet. Only create a preview when we can name an
        // fsType — either from the event's `kind` ("ext4.probe" →
        // ext4) or from a `fs` field on a `volume.info` event.
        // Without a real fsType, this would be a phantom Local
        // Drives row (e.g. an FSKit extension probe of an empty
        // SD-reader slot emits a kind we can't decode and no `fs`
        // field). Empty-fsType events get queued — if a real
        // structured event with fsType info arrives later we
        // create the row and replay the queue. Empty drives
        // belong in the Empty Drives sidebar section sourced from
        // RawDisksModel, not here.
        let inferredFs = DiskEventHandler.fsTypeFromEventKind(kind)
        let fieldFs = (kind == "volume.info") ? fields["fs"] : nil
        let fsType = inferredFs ?? fieldFs ?? ""
        guard !fsType.isEmpty else {
            pendingEvents[bsd, default: []].append((kind: kind, fields: fields))
            return
        }

        let preview = AttachedDisk(
            bsd: bsd,
            mountPath: "",
            devicePath: "/dev/\(bsd)",
            fsType: fsType,
            name: bsd,
            isWritable: true,  // assumed writable; corrected on first refresh()
            status: .mounting
        )
        disks.append(preview)
        AppLog.shared.info("preview row added for \(bsd) (\(fsType))")
        DiskEventHandler.applyEventInPlace(kind: kind, fields: fields, to: &disks[disks.count - 1])
    }

    /// Apply a plain NDJSON log line to the matching disk's partition
    /// log. Same matching as `applyExtensionEvent`: lines for an
    /// unknown BSD create a preview row so the partition-log strip is
    /// populated from the moment the extension starts emitting.
    public func applyLogLine(_ line: ParsedLogLine) {
        guard let bsd = line.bsd else { return }
        let entry = AttachedDiskLogLine(
            timestamp: line.timestamp,
            level: line.level,
            message: line.message,
            source: line.source,
            scope: line.scope
        )
        let idx: Int
        if let existing = disks.firstIndex(where: { $0.bsd == bsd }) {
            idx = existing
        } else {
            // No row yet, no fsType to infer (log lines don't carry
            // one). Always queue rather than creating a preview — same
            // rule as applyExtensionEvent now uses for empty-fsType
            // events. Old behaviour created a "fs unknown" preview
            // that lingered in Local Drives forever for empty SD-reader
            // probe noise; the queue gets replayed when (if) a real
            // structured event with fsType arrives.
            pendingLogs[bsd, default: []].append(entry)
            if pendingLogs[bsd]!.count > Self.logCap {
                pendingLogs[bsd]!.removeFirst(pendingLogs[bsd]!.count - Self.logCap)
            }
            return
        }
        disks[idx].partitionLog.append(entry)
        if disks[idx].partitionLog.count > Self.logCap {
            disks[idx].partitionLog.removeFirst(disks[idx].partitionLog.count - Self.logCap)
        }
    }

}
