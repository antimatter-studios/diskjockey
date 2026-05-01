import Foundation
import Combine
import ServiceManagement
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

        // Spike: register privileged mount helper + ping it. Logs the
        // pid/uid/euid the helper reports back so we can confirm
        // launchd actually spawned it as root and that the binary
        // wasn't rejected by Launch Constraint Validation. If
        // registration fails or ping times out, the user has to
        // approve "DiskJockey" in System Settings → Login Items &
        // Extensions → Background.
        Self.registerAndPingMountHelper()
    }

    private static func registerAndPingMountHelper() {
        // Agent (user context, unsandboxed) — NOT daemon (root context,
        // sandboxed apps can't register). The agent calls DADiskMount on
        // our behalf, bypassing the sandbox veto on
        // `system.volume.removable.mount` that authd raises against the
        // host app's direct DA call.
        let plistName = "com.antimatterstudios.diskjockey.mounthelper.plist"
        let helper = SMAppService.agent(plistName: plistName)

        // SMAppService is idempotent — register() on an already-registered
        // service just re-validates. Errors are usually "approval required"
        // (status .requiresApproval), which is informational, not fatal.
        do {
            try helper.register()
            AppLog.shared.info(
                "MountHelper: register OK — status=\(helper.status.rawValue)")
        } catch {
            AppLog.shared.warn(
                "MountHelper: register failed — \(error.localizedDescription) "
                + "status=\(helper.status.rawValue) "
                + "(check System Settings → Login Items & Extensions → Background)")
            return
        }

        // Try a ping. Will fail until the user approves the helper.
        let conn = NSXPCConnection(
            machServiceName: mountHelperMachServiceName,
            options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: MountHelperProtocol.self)
        conn.invalidationHandler = {
            AppLog.shared.warn("MountHelper: XPC connection invalidated")
        }
        conn.interruptionHandler = {
            AppLog.shared.warn("MountHelper: XPC connection interrupted")
        }
        conn.resume()

        let proxy = conn.remoteObjectProxyWithErrorHandler { err in
            AppLog.shared.error("MountHelper: XPC proxy error — \(err.localizedDescription)")
        } as? MountHelperProtocol

        proxy?.ping { reply in
            AppLog.shared.info("MountHelper: ping → \(reply)")
        }
    }
}
