//
// EXT4Watchdog.swift — the parent-death / stuck-progress watchdog for this
// extension, lifted out of the principal class.
//
// It was `EXT4FileSystem.watchdog` plus three statics beside it. Nothing in
// it referenced the class: it reads two App Group defaults, builds a
// `DetachedOperationWatchdog`, and logs. What it DID do, by living there,
// was make `EXT4Volume.swift` depend on the appex's entry point for a
// single call — `EXT4FileSystem.scheduleWatchdogIfNeeded()` — which is the
// only reason 903 lines of volume implementation could not be compiled or
// tested outside the extension bundle.
//
// `EXT4FileSystem` keeps `enterOperation` / `exitOperation` as forwarders,
// so the call sites in EXT4Maintenance and RepairXPCService are unchanged.
//

import Foundation
import DiskJockeyLibrary

enum EXT4Watchdog {
    /// Shared parent-death watchdog for fsck / repair / format. See
    /// `DetachedOperationWatchdog` for the rationale. The `onExpire`
    /// closure logs + exits the process so `storagekitd` respawns the
    /// appex cleanly. Was `EXT4FileSystem.watchdog`.
    static let shared: DetachedOperationWatchdog = {
        // Fix D — stuck-progress monitor. If `heartbeat()` doesn't
        // fire for `stuckDeadline` seconds while at least one op
        // is in flight, the op is presumed wedged (e.g. fsck stuck
        // on a corrupted inode loop) and the appex `exit`s the
        // same way deactivate-watchdog does. Default 60 s,
        // overridable via the App Group default
        // `ext4StuckDeadlineSeconds` (read once at static-let init
        // time, same one-shot pattern as the deactivate side's
        // `ext4WatchdogDeadlineSeconds` override).
        let defaults = UserDefaults(suiteName: AppLog.groupIdentifier)
        let configuredStuck = defaults?.double(forKey: "ext4StuckDeadlineSeconds") ?? 0
        let stuckDeadline: TimeInterval = configuredStuck > 0 ? configuredStuck : 60
        return DetachedOperationWatchdog(
            label: "ext4",
            defaultDeadline: 30,
            stuckDeadline: stuckDeadline
        ) { pending, deadline in
            log.error(
                "watchdog: \(pending) op(s) still pending after \(Int(deadline))s — exiting (EX_TEMPFAIL) so storagekitd respawns",
                scope: AppLogScope.lifecycle
            )
            exit(Int32(EX_TEMPFAIL))
        }
    }()

    static func enter() { shared.enter() }
    static func leave() { shared.leave() }

    /// Called from `EXT4Volume.deactivate` after the volume's normal
    /// teardown. Consults the App Group default
    /// `ext4WatchdogDeadlineSeconds` to allow runtime extension for
    /// slow-disk diagnostics without recompiling.
    static func scheduleExpiryIfNeeded() {
        let defaults = UserDefaults(suiteName: AppLog.groupIdentifier)
        let configured = defaults?.double(forKey: "ext4WatchdogDeadlineSeconds") ?? 0
        let deadline: TimeInterval? = configured > 0 ? configured : nil
        let pending = shared.pending
        let scheduled = shared.scheduleExpiryIfNeeded(deadline: deadline)
        if scheduled {
            let effective = deadline ?? shared.defaultDeadline
            log.warn(
                "deactivate: \(pending) detached op(s) still in flight; watchdog will exit appex in \(Int(effective))s if not done",
                scope: AppLogScope.lifecycle
            )
        }
    }
}
