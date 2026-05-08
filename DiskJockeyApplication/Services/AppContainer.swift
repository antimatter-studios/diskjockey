import Foundation
import Combine
import DiskJockeyLibrary

/// Dependency container for the host app. Every service the UI needs
/// is built once here and handed down via view init.
///
/// No backend coupling — all network-filesystem mounts go through
/// `DirectMountRegistry`, which links `libnetworkfs.a` directly into
/// the FileProvider extension. Subprocess logs are tailed from ndjson
/// files in the shared app-group container.
@MainActor
public final class AppContainer: ObservableObject {
    /// Ingest point for subprocess log lines (FileProvider extension,
    /// FSKit extensions). Drives the Logs view.
    public let logRepository: LogRepository

    /// Structured app-level log surface (AppLog wraps writes to the
    /// shared ndjson file so our own lines appear in the same feed).
    public let appLogModel: AppLogModel
    public var appLogger: AppLogger { appLogModel as! AppLogger }

    /// Owns the security-scoped bookmark the user approves on first
    /// direct-mount creation — grants the sandboxed host app access
    /// to whatever folder they pick to hold mount symlinks.
    public let homeAccess: HomeAccessService

    /// Manages `$HOME/<picked>/<name>` symlinks pointing at
    /// FileProvider user-visible URLs. Shared by `DirectMountRegistry`.
    public let symlinkManager: SymlinkManager

    /// Authoritative store of direct-linked network mounts (ftp, sftp,
    /// smb, dropbox, webdav, gdrive, s3, onedrive). Persisted under the
    /// shared app-group container; every entry is self-contained (no
    /// backend handshake).
    public let directMountRegistry: DirectMountRegistry

    /// Watches `mount.error` events from the FileProvider extension
    /// for a dead-OAuth-refresh-token signal and auto-runs
    /// re-authorisation (browser opens, new tokens land in the
    /// keychain, the FileProvider domain is cycled). Eliminates the
    /// "Sign in again in mount settings" manual step for Dropbox /
    /// Google Drive / OneDrive mounts. Owned here so it lives as long
    /// as `directMountRegistry` does.
    public let oauthRefreshSupervisor: OAuthRefreshSupervisor

    /// Enumerates system-mounted disks (ext4 / ntfs via our FSKit
    /// extensions) so the sidebar can show them. Read-only.
    public let attachedDisks: AttachedDisksModel = AttachedDisksModel()

    /// Enumerates *unmounted* / *unformatted* block devices via diskutil
    /// polling. Sibling of `attachedDisks` — anything without a working
    /// filesystem (blank SD card, GPT-partitioned disk with empty slices,
    /// etc.) is invisible to `AttachedDisksModel` because that one only
    /// sees what `/sbin/mount` reports. The sidebar's "Unformatted Disks"
    /// section reads `formatableDisks` off this; the format / partition
    /// actions in the detail view operate on entries here.
    public let rawDisks: RawDisksModel = RawDisksModel()

    /// Surfaced error for the UI to display as an alert.
    @Published public private(set) var error: Error?

    private var logTailService: LogTailService?
    /// Subscribes to macOS DiskArbitration events so already-attached
    /// disks (mounted before the app launched, or by a prior session)
    /// get their identity populated in `attachedDisks` without needing
    /// the FSKit extension to re-probe. Also exposes a `mount(bsd:)`
    /// entry point for the offline-row Mount button — DA's
    /// `DADiskMount` is the only mount path that reliably reaches our
    /// FSKit extensions on macOS 26.
    internal private(set) var diskArbitration: DiskArbitrationService?

    public init() {
        self.logRepository = LogRepository()
        self.appLogModel = AppLogModel(logRepository: self.logRepository)

        let home = HomeAccessService()
        self.homeAccess = home
        let symlinks = SymlinkManager(access: home)
        self.symlinkManager = symlinks
        self.directMountRegistry = DirectMountRegistry(symlinks: symlinks)

        // OAuth refresh-token recovery. Hooks the registry's
        // mount.error firehose; when the underlying error is a
        // dead-refresh signal (`oauth_reauth_required` /
        // `invalid_grant`), the supervisor opens the browser, runs
        // the same flow as initial sign-in, and writes the new tokens
        // back. Set up before LogTailService.start() so the very
        // first event after launch can already trigger recovery.
        let supervisor = OAuthRefreshSupervisor(
            registry: self.directMountRegistry
        )
        self.oauthRefreshSupervisor = supervisor
        self.directMountRegistry.onMountError = { [weak supervisor] domainID, err in
            supervisor?.handleMountError(domainID: domainID, error: err)
        }

        // Sweep stale `<picked>/<name>` symlinks whose targets no
        // longer exist (domain removed while app was closed, extension
        // died, etc.). Silently skips if no folder picked yet.
        symlinks.sweepDangling()

        // Log the FP-domain vs persisted-mount state so we can debug
        // "app says mounted but it's not" mismatches from Console.app.
        let registry = self.directMountRegistry
        Task { await registry.reconcile() }

        // Populate the sidebar BEFORE we start replaying ndjson events.
        // Ordering matters: on launch the tail reads existing lines from
        // each ndjson file; if the disk model hasn't polled mount(8) yet
        // those events would match no disk and get dropped.
        self.attachedDisks.start()
        self.rawDisks.start()

        // Tail subprocess NDJSON log files. Lines flow into the central
        // logRepository; kind-tagged events (volume.clean/dirty,
        // volume.info, fsck.start/progress/done/failed) plus generic
        // per-bsd log lines also route to AttachedDisksModel so the
        // per-disk detail pane shows live status, identity, and a
        // partition-scoped log.
        let tail = LogTailService(logRepository: self.logRepository)
        let disks = self.attachedDisks
        let registryForLog = self.directMountRegistry
        tail.onEvent = { kind, fields in
            // Every event goes to both routers; each filters on its own
            // routing key (AttachedDisksModel requires `bsd`,
            // DirectMountRegistry requires `mount`). `io.stats` in
            // particular needs to reach both — FSKit emitters tag with
            // `bsd`, FileProvider with `mount`.
            disks.applyExtensionEvent(kind: kind, fields: fields)
            registryForLog.applyExtensionEvent(kind: kind, fields: fields)
        }
        tail.onLine = { line in
            // Every line goes to both routers; each drops lines it
            // doesn't own (AttachedDisksModel requires `bsd`,
            // DirectMountRegistry requires `mount`).
            disks.applyLogLine(line)
            registryForLog.applyLogLine(line)
        }
        tail.start()
        self.logTailService = tail

        // DiskArbitration session — replays appearance events for every
        // currently-attached disk on registration, populating
        // stableIdentity for disks the FSKit extension already mounted
        // in a prior session (and won't re-probe). Must be initialised
        // AFTER attachedDisks so the synthetic volume.info events have
        // a target.
        self.diskArbitration = DiskArbitrationService(attachedDisks: self.attachedDisks)

        AppLog.shared.info("DiskJockey launched — log tail started")
    }
}
