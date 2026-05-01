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
/// conditional third line ("Verifying disk…", "Offline since …").
///
///   - `.mounting` — created from extension events (probe / loadResource /
///     fsck.start) but not yet visible in `/sbin/mount`. The preview-row
///     state. macOS auto-probe → loadResource → fsck → mount; the entry
///     gets created on probe so the user sees "something is happening"
///     during the multi-minute fsck window before the path appears.
///   - `.live` — currently in `/sbin/mount`.
///   - `.offline(since:)` — was live, has dropped out. Kept in the
///     sidebar so the user can read the partition log to investigate
///     why a disk disappeared.
public enum AttachedDiskStatus: Equatable, Hashable {
    case mounting
    case live
    case offline(since: Date)
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
    /// that haven't reached mount(8) yet, and for `.offline` rows
    /// where we keep the last known path in `lastMountPath` instead.
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
    /// Last `mountPath` we saw this disk at. Survives the transition to
    /// `.offline` (where `mountPath` is cleared) and across app
    /// restarts via the persistence cache. Lets the detail view show
    /// "was at /Volumes/Foo" for offline rows.
    public var lastMountPath: String?
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
                lastMountPath: String? = nil,
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
        self.lastMountPath = lastMountPath ?? (mountPath.isEmpty ? nil : mountPath)
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
    ///   - was live earlier this session, has dropped out
    ///     (status = .offline)
    ///   - was live in a previous session and persisted via UserDefaults
    ///     (status = .offline, restored from disk on init)
    /// Any mutation triggers `persist()` via didSet so the offline
    /// roster survives an app restart.
    @Published public private(set) var disks: [AttachedDisk] = [] {
        didSet { persist() }
    }

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

    /// JSON file holding the persisted history of disks we've seen
    /// with a `stableIdentity`. Restored at launch as `.offline` rows
    /// so the user can investigate a disk that was unmounted before
    /// the app was last quit, or so a still-mounted disk reattaches
    /// to its existing row before mount(8) re-enumeration completes.
    /// Rows without `stableIdentity` (e.g. ext4 disks where we can't
    /// read the UUID) are NOT persisted — the BSD they're keyed on
    /// is meaningless across reboots.
    ///
    /// Stored in the App Group container — same dir tree as the NDJSON
    /// logs (see `AppLog.groupIdentifier`). Inspectable with `cat`,
    /// wipeable with `rm`, no UserDefaults voodoo. Schema is versioned
    /// so a future field addition can either migrate or skip cleanly.
    private static let persistenceFilename = "AttachedDisks.v1.json"

    public init(pollInterval: TimeInterval = 3.0) {
        self.pollInterval = pollInterval
        self.disks = Self.loadPersisted()
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

    // MARK: - Persistence

    /// Snapshot of the bare-minimum fields needed to recreate a disk's
    /// sidebar row across an app restart. Deliberately doesn't include
    /// partitionLog / ioStats / fsckStatus — those are session-scoped
    /// and would be misleading if rendered from a previous run.
    ///
    /// `stableIdentity` is optional: rows that have it survive replug
    /// + reboot. Rows without it (no `volume.info` yet, e.g. a disk
    /// already mounted from a prior session) are still persisted so
    /// the sidebar isn't empty after a relaunch — they just won't
    /// coalesce across a BSD change. The fallback is keyed on `bsd`
    /// so an in-session restart works.
    private struct PersistedRow: Codable {
        let stableIdentity: String?
        let lastBsd: String?
        let lastMountPath: String?
        let lastDevicePath: String
        let fsType: String
        let name: String
        let lastSeenAt: Date
        let info: [String: String]
    }

    /// Versioned envelope for the JSON file. Lets us add fields to
    /// `PersistedRow` later (or migrate the row shape) without
    /// silently corrupting an old cache — a bumped `version` triggers
    /// a clean discard rather than a half-decoded mess.
    private struct PersistedSnapshot: Codable {
        let version: Int
        let savedAt: Date
        let rows: [PersistedRow]
    }

    /// Resolve the on-disk path for the snapshot file. Returns nil only
    /// if the App Group container isn't accessible, which would mean
    /// the entitlement is misconfigured — we fall back to skipping
    /// persistence rather than dropping the file in `tmp` where it
    /// would silently disappear.
    private static func persistenceURL() -> URL? {
        let fm = FileManager.default
        guard let base = fm.containerURL(
            forSecurityApplicationGroupIdentifier: AppLog.groupIdentifier
        ) else { return nil }
        return base.appendingPathComponent(persistenceFilename, isDirectory: false)
    }

    private static func loadPersisted() -> [AttachedDisk] {
        guard let url = persistenceURL() else {
            AppLog.shared.warn("AttachedDisks: persistence URL unavailable (app group entitlement?) — starting with empty history")
            return []
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            AppLog.shared.info("AttachedDisks: no persisted history at \(url.path) (first launch?)")
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(PersistedSnapshot.self, from: data)
            AppLog.shared.info("AttachedDisks: loaded \(snapshot.rows.count) persisted rows (savedAt=\(snapshot.savedAt))")
            return snapshot.rows.map { row in
                AttachedDisk(
                    stableIdentity: row.stableIdentity,
                    bsd: row.lastBsd,
                    mountPath: "",
                    devicePath: row.lastDevicePath,
                    fsType: row.fsType,
                    name: row.name,
                    isWritable: true,
                    status: .offline(since: row.lastSeenAt),
                    lastMountPath: row.lastMountPath,
                    info: row.info
                )
            }
        } catch {
            AppLog.shared.warn("AttachedDisks: failed to decode \(url.lastPathComponent) — \(error.localizedDescription)")
            return []
        }
    }

    /// Snapshot the current `disks` to the App Group JSON file. Called
    /// from didSet of `disks` so any mutation that goes through the
    /// published property (refresh, applyEvent, applyLogLine, forget)
    /// gets saved.
    ///
    /// Saved if EITHER `stableIdentity` (best — survives replug) OR
    /// `bsd` (good enough within a session) is known. Rows with
    /// neither are noise — they're transient parse failures that
    /// haven't reached the model's identity-tracking logic yet.
    ///
    /// Atomic write: encode → tmp file → rename. A partial write or
    /// crash mid-encode leaves the previous valid snapshot in place
    /// rather than a truncated file the next launch can't decode.
    private func persist() {
        guard let url = Self.persistenceURL() else { return }
        let rows: [PersistedRow] = disks.compactMap { d in
            let hasStable = !(d.stableIdentity ?? "").isEmpty
            let hasBsd = !(d.bsd ?? "").isEmpty
            guard hasStable || hasBsd else { return nil }
            let lastSeen: Date
            switch d.status {
            case .offline(let since): lastSeen = since
            case .live, .mounting:    lastSeen = Date()
            }
            return PersistedRow(
                stableIdentity: d.stableIdentity,
                lastBsd: d.bsd,
                lastMountPath: d.lastMountPath ?? (d.mountPath.isEmpty ? nil : d.mountPath),
                lastDevicePath: d.devicePath,
                fsType: d.fsType,
                name: d.name,
                lastSeenAt: lastSeen,
                info: d.info
            )
        }
        let snapshot = PersistedSnapshot(version: 1, savedAt: Date(), rows: rows)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.shared.warn("AttachedDisks: persist failed — \(error.localizedDescription)")
        }
    }

    public func refresh() {
        let fresh = Self.enumerate(fsTypesOfInterest: fsTypesOfInterest)
        var merged: [AttachedDisk] = []
        var consumedIndices: Set<Int> = []  // indices into `disks` we've already merged
        let now = Date()

        // For each fresh mount(8) entry, find the best-matching existing
        // row and merge state forward (or create a new live row).
        // Cascade: stableIdentity → bsd → mountPath. The first match
        // wins and that prior index is consumed so it isn't carried
        // again as a stale offline entry. This is what lets a disk
        // unplugged + replugged with a different BSD coalesce back
        // onto its original sidebar row.
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
                copy.lastMountPath = f.mountPath
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

        // Anything that didn't get consumed wasn't in mount(8): either
        // a `.mounting` preview that hasn't reached mount-table yet
        // (keep as-is), or a previously-`.live` row that just dropped
        // out (flip to `.offline`).
        for (i, prior) in disks.enumerated() where !consumedIndices.contains(i) {
            var carried = prior
            switch prior.status {
            case .live:
                carried.status = .offline(since: now)
                carried.mountPath = ""  // no longer mounted there
            case .mounting, .offline:
                break  // preserve as-is
            }
            merged.append(carried)
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
                    Self.applyEventInPlace(kind: ev.kind, fields: ev.fields, to: &merged[i])
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
        let newIDs = Set(merged.map { $0.id })
        for added in merged where !oldIDs.contains(added.id) && added.status == .live {
            AppLog.shared.info("attached: \(added.fsType) at \(added.mountPath) (\(added.devicePath))")
        }
        for (i, prior) in disks.enumerated() where !consumedIndices.contains(i) && prior.status == .live && newIDs.contains(prior.id) {
            AppLog.shared.info("detached: \(prior.lastMountPath ?? prior.mountPath) (kept in sidebar as offline)")
        }
        disks = merged
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
        // mountPath is currently set; offline rows clear it.
        if !f.mountPath.isEmpty {
            for (i, p) in prior.enumerated() where !excluded.contains(i) {
                if p.mountPath == f.mountPath && !p.mountPath.isEmpty { return i }
            }
        }
        return nil
    }

    /// Drop a disk row entirely. Triggered by the user's "Forget" action
    /// in the detail view — typically used on offline rows once the
    /// user has finished investigating, but allowed on live rows too
    /// (the next refresh() will resurrect a live row anyway).
    public func forget(id: String) {
        guard let idx = disks.firstIndex(where: { $0.id == id }) else { return }
        let removed = disks.remove(at: idx)
        AppLog.shared.info("forgot: \(removed.lastMountPath ?? removed.mountPath) (id=\(removed.id))")
    }

    /// Strip "/dev/" prefix off a devicePath. Uses prefix match so
    /// "/dev/disk6s2" → "disk6s2"; callers comparing against event
    /// `bsd` keys should match with hasPrefix.
    nonisolated private static func bsdName(from devicePath: String) -> String {
        if devicePath.hasPrefix("/dev/") {
            return String(devicePath.dropFirst("/dev/".count))
        }
        return devicePath
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
        let idx: Int
        if let existing = disks.firstIndex(where: { $0.bsd == bsd }) {
            idx = existing
        } else {
            // No row yet — create a preview. fsType comes from the
            // event kind prefix ("ext4.probe", "ntfs.load", …) when
            // available, otherwise blank until volume.info arrives.
            let fsType = Self.fsTypeFromEventKind(kind) ?? ""
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
            idx = disks.count - 1
            AppLog.shared.info("preview row added for \(bsd) (\(fsType.isEmpty ? "fs unknown" : fsType))")
        }
        Self.applyEventInPlace(kind: kind, fields: fields, to: &disks[idx])
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
            // Create a preview keyed on this bsd. Plain log lines
            // don't carry a kind, so we can't infer fsType yet —
            // leave it blank and let the next structured event fill
            // it in.
            let preview = AttachedDisk(
                bsd: bsd,
                mountPath: "",
                devicePath: "/dev/\(bsd)",
                fsType: "",
                name: bsd,
                isWritable: true,
                status: .mounting
            )
            disks.append(preview)
            idx = disks.count - 1
        }
        disks[idx].partitionLog.append(entry)
        if disks[idx].partitionLog.count > Self.logCap {
            disks[idx].partitionLog.removeFirst(disks[idx].partitionLog.count - Self.logCap)
        }
    }

    /// Map a structured-event `kind` (e.g. `"ext4.probe"`, `"ntfs.load"`)
    /// to the fsType the model should render in the sidebar. Returns
    /// nil for kinds that aren't fs-specific (`"fsck.progress"`,
    /// `"io.stats"`, `"volume.info"` — the latter has the fs name in
    /// `fields["fs"]` so callers can pull from there).
    private static func fsTypeFromEventKind(_ kind: String) -> String? {
        if kind.hasPrefix("ext4.") { return "ext4" }
        if kind.hasPrefix("ntfs.") { return "ntfs" }
        return nil
    }

    /// Mutating event-apply logic extracted so `refresh()` can replay
    /// buffered events directly into the merged array without going
    /// through the published `disks` property.
    private static func applyEventInPlace(kind: String, fields: [String: String], to disk: inout AttachedDisk) {
        if kind == "volume.info" {
            var info = fields
            info.removeValue(forKey: "bsd")
            if let bytes = materializeTotalSize(from: info) {
                info["total_size"] = String(bytes)
            }
            // Overlay onto existing (statvfs-populated) info rather than
            // replacing — so free_size from `refresh()` survives alongside
            // the fs-specific keys the extension emits.
            for (k, v) in info { disk.info[k] = v }
            // Promote preview rows: fill in fsType + display name + the
            // stable identity for cross-session/replug coalescing.
            if let fs = info["fs"], !fs.isEmpty {
                disk.fsType = fs
            }
            if let volName = info["volume_name"], !volName.isEmpty,
               (disk.name == disk.bsd || disk.name.isEmpty) {
                // Only adopt volume_name if the row is still showing
                // the BSD as a placeholder. Once mount(8) gives us a
                // real /Volumes path, that's what the user knows the
                // disk by — don't clobber it with the on-disk label.
                disk.name = volName
            }
            // Strongest identity wins. NTFS emits `serial_number` in
            // volume.info → survives replug+restart, sidebar row
            // coalesces back. Ext4 doesn't currently emit its UUID
            // (the rust FFI struct doesn't expose s_uuid yet) so ext4
            // disks fall back to BSD-as-identity, which is stable for
            // a session but not across replug. Prefix-tag so two
            // filesystems can't collide on the same string.
            if disk.stableIdentity == nil {
                if let u = info["volume_uuid"], !u.isEmpty {
                    disk.stableIdentity = "ext4-uuid:\(u)"
                } else if let s = info["serial_number"], !s.isEmpty {
                    disk.stableIdentity = "ntfs-serial:\(s)"
                }
            }
            return
        }

        if kind == "io.stats" {
            // 1 Hz heartbeat from the FSKit extension. Decode the
            // counter snapshot, let `IOStats.absorb` derive a per-second
            // throughput sample from the delta vs the previous snapshot,
            // and append it to the rolling buffer the detail view reads.
            disk.ioStats.absorb(IOCounters(fields: fields))
            return
        }

        let newStatus: FsckStatus
        switch kind {
        case "volume.clean":
            newStatus = .clean
        case "volume.dirty":
            newStatus = .dirty
        case "fsck.start":
            newStatus = .running(phase: "starting", done: 0, total: 0)
        case "fsck.progress":
            let phase = fields["phase"] ?? "?"
            let done = UInt64(fields["done"] ?? "0") ?? 0
            let total = UInt64(fields["total"] ?? "0") ?? 0
            newStatus = .running(phase: phase, done: done, total: total)
        case "fsck.done":
            let dirtyCleared = (fields["dirty_cleared"] ?? "false") == "true"
            let logfileBytes = UInt64(fields["logfile_bytes"] ?? "0") ?? 0
            newStatus = .completed(dirtyCleared: dirtyCleared, logfileBytes: logfileBytes)
        case "fsck.failed":
            newStatus = .failed(fields["error"] ?? "unknown error")
        default:
            return
        }
        disk.fsckStatus = newStatus
    }

    /// Runs `/sbin/mount` and parses each line into an AttachedDisk.
    /// Output format: `/dev/diskN on /Volumes/NAME (fstype, flag1, flag2, ...)`.
    /// Simpler + more portable than wrestling with Swift's `getfsstat`
    /// bridging, and mount(8) is always present.
    private static func enumerate(fsTypesOfInterest: Set<String>) -> [AttachedDisk] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return [] }
        proc.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var results: [AttachedDisk] = []
        for line in text.split(separator: "\n") {
            guard var disk = parseMountLine(String(line), fsTypesOfInterest: fsTypesOfInterest) else {
                continue
            }
            disk.info = statvfsInfo(
                mountPath: disk.mountPath, fsType: disk.fsType, volumeName: disk.name
            )
            results.append(disk)
        }
        return results.sorted { $0.mountPath < $1.mountPath }
    }

    /// Parse a single `/sbin/mount` output line into an AttachedDisk.
    /// Extracted from `enumerate` so the parser is reachable from tests
    /// without spawning a real `mount(8)`. Returns nil for malformed
    /// lines or fstypes outside the caller's interest set. Does not
    /// populate `info` — that's done by the live caller after parsing
    /// so the test path doesn't have to mock statvfs.
    nonisolated static func parseMountLine(_ line: String, fsTypesOfInterest: Set<String>) -> AttachedDisk? {
        // "/dev/diskN on /Volumes/Foo (fstype, flag1, flag2)"
        guard let onRange = line.range(of: " on ") else { return nil }
        let devicePath = String(line[..<onRange.lowerBound])
        let rest = line[onRange.upperBound...]
        guard let parenOpen = rest.range(of: " (") else { return nil }
        let mountPath = String(rest[..<parenOpen.lowerBound])
        let flagsStr = rest[parenOpen.upperBound...]
        guard let parenClose = flagsStr.range(of: ")", options: .backwards) else { return nil }
        let flagsBody = flagsStr[..<parenClose.lowerBound]
        let flags = flagsBody.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let fsType = flags.first else { return nil }
        guard fsTypesOfInterest.contains(fsType) else { return nil }

        // macOS mount(8) emits "read-only" for RO mounts; older / other
        // tools sometimes emit the bare token "ro". Treat both as RO.
        let isWritable = !flags.contains("read-only") && !flags.contains("ro")

        let name = (mountPath as NSString).lastPathComponent
        let bsd = Self.bsdName(from: devicePath)
        return AttachedDisk(
            bsd: bsd,
            mountPath: mountPath,
            devicePath: devicePath,
            fsType: fsType,
            name: name,
            isWritable: isWritable
        )
    }

    /// Compute the concrete `total_size` in bytes for a managed
    /// filesystem's `volume.info` event. Dispatches by the `fs` field
    /// the extension emits, so each case uses the exact fields it
    /// knows it wrote — no "does this key exist" probing. Returns
    /// `nil` for fs types we don't own (the statvfs baseline already
    /// provided `total_size` for those at enumerate-time).
    private static func materializeTotalSize(from fields: [String: String]) -> UInt64? {
        switch fields["fs"] ?? "" {
        case "ext4":
            let blocks = UInt64(fields["total_blocks"] ?? "") ?? 0
            let blockSize = UInt64(fields["block_size"] ?? "") ?? 0
            let (product, overflow) = blocks.multipliedReportingOverflow(by: blockSize)
            return overflow ? nil : product
        case "ntfs":
            return UInt64(fields["total_size"] ?? "")
        default:
            return nil
        }
    }

    /// Cross-filesystem baseline info derived from `FileManager`'s wrapper
    /// around `statvfs(2)`. Populated at enumerate-time for every mounted
    /// partition — including msdos, exfat, apfs, hfs+, and other types
    /// DiskJockey doesn't have an FSKit extension for — so the detail
    /// view can show total / free size without waiting on a `volume.info`
    /// event that will never come for non-DJ-managed filesystems. For
    /// DJ-managed (ext4, ntfs), the richer event overlays fs-specific
    /// keys (block_size, total_inodes, serial_number, …) on top of this
    /// baseline in `refresh()`.
    private static func statvfsInfo(
        mountPath: String, fsType: String, volumeName: String
    ) -> [String: String] {
        var out: [String: String] = [
            "fs": fsType,
            "volume_name": volumeName,
        ]
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: mountPath) {
            if let total = attrs[.systemSize] as? NSNumber {
                out["total_size"] = String(total.uint64Value)
            }
            if let free = attrs[.systemFreeSize] as? NSNumber {
                out["free_size"] = String(free.uint64Value)
            }
        }
        return out
    }
}
