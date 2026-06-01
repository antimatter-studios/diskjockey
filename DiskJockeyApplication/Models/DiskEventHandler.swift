//
// DiskEventHandler.swift — static event-to-state transforms that
// `AttachedDisksModel.applyExtensionEvent` and `applyLogLine` invoke
// for each FSKit-extension event arriving over the per-mount NDJSON
// log.
//
// Extracted from `AttachedDisksModel` so the pure event-shape logic
// (which kind maps to which fsType, which fields decode into what
// FsckStatus, how `volume.info` overlays existing info) is testable
// in isolation. The model still owns the @MainActor mutation of
// `disks` — these helpers operate on an `inout AttachedDisk` so the
// owning model decides where the disk lives.
//

import Foundation
import DiskJockeyLibrary

public enum DiskEventHandler {

    /// Map a structured-event `kind` (e.g. `"ext4.probe"`, `"ntfs.load"`)
    /// to the fsType the model should render in the sidebar. Returns
    /// nil for kinds that aren't fs-specific (`"fsck.progress"`,
    /// `"io.stats"`, `"volume.info"` — the latter has the fs name in
    /// `fields["fs"]` so callers can pull from there).
    public static func fsTypeFromEventKind(_ kind: String) -> String? {
        if kind.hasPrefix("ext4.") { return "ext4" }
        if kind.hasPrefix("ntfs.") { return "ntfs" }
        return nil
    }

    /// Mutating event-apply logic. The model invokes this when it has
    /// already located the right `AttachedDisk` row (or built a preview
    /// for one). Branches on `kind` and dispatches to the appropriate
    /// sub-helper or `fsckStatus` decoder.
    public static func applyEventInPlace(kind: String,
                                         fields: [String: String],
                                         to disk: inout AttachedDisk) {
        if kind == "volume.info" {
            applyVolumeInfo(fields: fields, to: &disk)
            return
        }

        if kind == "io.stats" {
            // 1 Hz heartbeat from the FSKit extension. Decode the
            // counter snapshot, let `IOStats.absorb` derive a
            // per-second throughput sample from the delta vs the
            // previous snapshot, and append it to the rolling buffer
            // the detail view reads.
            disk.ioStats.absorb(IOCounters(fields: fields))
            return
        }

        guard let newStatus = fsckStatus(kind: kind, fields: fields, disk: &disk) else { return }
        disk.fsckStatus = newStatus
    }

    /// Apply a `volume.info` event payload onto `disk`. Overlays
    /// fields, promotes fsType, adopts volume_name when still showing
    /// the BSD as a placeholder, and assigns `stableIdentity` on first
    /// encounter.
    public static func applyVolumeInfo(fields: [String: String],
                                       to disk: inout AttachedDisk) {
        var info = fields
        info.removeValue(forKey: "bsd")
        if let bytes = materializeTotalSize(from: info) {
            info["total_size"] = String(bytes)
        }
        // Overlay onto existing (statvfs-populated) info rather than
        // replacing — so free_size from `refresh()` survives alongside
        // the fs-specific keys the extension emits.
        for (k, v) in info { disk.info[k] = v }
        if let fs = info["fs"], !fs.isEmpty {
            disk.fsType = fs
        }
        if let volName = info["volume_name"], !volName.isEmpty,
           (disk.name == disk.bsd || disk.name.isEmpty) {
            // Only adopt volume_name if the row is still showing the
            // BSD as a placeholder. Once mount(8) gives us a real
            // /Volumes path, that's what the user knows the disk by —
            // don't clobber it with the on-disk label.
            disk.name = volName
        }
        // Strongest identity wins. NTFS emits `serial_number` in
        // volume.info → survives replug+restart, sidebar row
        // coalesces back. Ext4 doesn't currently emit its UUID (the
        // rust FFI struct doesn't expose s_uuid yet) so ext4 disks
        // fall back to BSD-as-identity, which is stable for a session
        // but not across replug. Prefix-tag so two filesystems can't
        // collide on the same string.
        if disk.stableIdentity == nil {
            if let u = info["volume_uuid"], !u.isEmpty {
                disk.stableIdentity = "ext4-uuid:\(u)"
            } else if let s = info["serial_number"], !s.isEmpty {
                disk.stableIdentity = "ntfs-serial:\(s)"
            }
        }
    }

    /// Compute the concrete `total_size` in bytes for a managed
    /// filesystem's `volume.info` event. Dispatches by the `fs` field
    /// the extension emits, so each case uses the exact fields it
    /// knows it wrote — no "does this key exist" probing. Returns
    /// `nil` for fs types we don't own (the statvfs baseline already
    /// provided `total_size` for those at enumerate-time).
    public static func materializeTotalSize(from fields: [String: String]) -> UInt64? {
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

    /// Return the new `FsckStatus` for fsck-family events, or nil for
    /// unknown kinds. Side-effects `disk.lastRepairedCount` and
    /// `disk.lastAnomaliesFound` on `fsck.done`.
    public static func fsckStatus(
        kind: String, fields: [String: String], disk: inout AttachedDisk
    ) -> FsckStatus? {
        switch kind {
        case "volume.clean":
            return .clean
        case "volume.dirty":
            return .dirty
        case "fsck.start":
            return .running(phase: "starting", done: 0, total: 0)
        case "fsck.progress":
            let phase = fields["phase"] ?? "?"
            let done = UInt64(fields["done"] ?? "0") ?? 0
            let total = UInt64(fields["total"] ?? "0") ?? 0
            return .running(phase: phase, done: done, total: total)
        case "fsck.done":
            let dirtyCleared = (fields["dirty_cleared"] ?? "false") == "true"
            let logfileBytes = UInt64(fields["logfile_bytes"] ?? "0") ?? 0
            if let raw = fields["repaired_count"], let n = UInt64(raw) {
                disk.lastRepairedCount = n
            }
            if let raw = fields["anomalies"], let n = UInt64(raw) {
                disk.lastAnomaliesFound = n
            }
            return .completed(dirtyCleared: dirtyCleared, logfileBytes: logfileBytes)
        case "fsck.failed":
            return .failed(fields["error"] ?? "unknown error")
        default:
            return nil
        }
    }
}
