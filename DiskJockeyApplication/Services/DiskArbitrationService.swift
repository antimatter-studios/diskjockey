//
// DiskArbitrationService.swift — bridges macOS DiskArbitration callbacks
// into AttachedDisksModel.
//
// Why this exists: when DiskJockey launches with a disk *already*
// mounted (from a prior session, plugged in while app was closed,
// inserted before the app was running), the FSKit extension does NOT
// re-probe and does NOT re-emit `volume.info`. Without that event the
// sidebar row exists (refresh() finds it in /sbin/mount) but has no
// `stableIdentity`, so persistence can't survive a reboot.
//
// DiskArbitration solves this. `DARegisterDiskAppearedCallback` fires
// once for every disk currently in the system the moment we register —
// not just on insertion events. Each fired callback gives us the
// disk's identity via `DADiskCopyDescription` (BSD, volume UUID,
// volume name, fs kind). We synthesise a `volume.info` event into
// `AttachedDisksModel.applyExtensionEvent` so the existing dispatch
// path populates `stableIdentity` and `info` exactly as if the FSKit
// extension had emitted it.
//
// MIT License — see LICENSE
//

import Foundation
import DiskArbitration
import DiskJockeyLibrary

@MainActor
final class DiskArbitrationService {
    private let session: DASession
    private weak var attachedDisks: AttachedDisksModel?

    init(attachedDisks: AttachedDisksModel) {
        self.attachedDisks = attachedDisks
        // Force-unwrap is acceptable: DASessionCreate only returns nil on
        // catastrophic CF allocation failure, which can't be recovered
        // from at app-init time anyway.
        self.session = DASessionCreate(kCFAllocatorDefault)!
        DASessionScheduleWithRunLoop(
            session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        // Appearance callback — fires for every currently-attached disk
        // on first registration, then on every subsequent insertion.
        // No matching dictionary (second arg = nil) so we get all disks
        // and filter inside the handler.
        DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
            guard let ctx = ctx else { return }
            let me = Unmanaged<DiskArbitrationService>.fromOpaque(ctx).takeUnretainedValue()
            // Hop to the main actor so model mutations are safe.
            // DA callbacks fire on the run-loop we scheduled with,
            // which IS the main run loop, but Swift's actor isolation
            // checker doesn't know that — `Task { @MainActor }` makes
            // it explicit.
            Task { @MainActor in me.handleAppeared(disk) }
        }, context)

        DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in
            guard let ctx = ctx else { return }
            let me = Unmanaged<DiskArbitrationService>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in me.handleDisappeared(disk) }
        }, context)

        AppLog.shared.info("DiskArbitration: session registered")
    }

    deinit {
        DASessionUnscheduleFromRunLoop(
            session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    // MARK: - Callback handlers

    private func handleAppeared(_ disk: DADisk) {
        guard let descCF = DADiskCopyDescription(disk) else { return }
        let desc = descCF as NSDictionary

        // Skip non-leaf disks (whole disks like "disk5") — we only care
        // about volumes. RawDisksModel handles whole-disk enumeration
        // separately.
        let isLeaf = (desc[kDADiskDescriptionMediaLeafKey as String] as? NSNumber)?.boolValue
            ?? false
        guard isLeaf else { return }

        guard let bsd = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String,
              !bsd.isEmpty else { return }

        // Build the synthetic event fields. Use the same keys the FSKit
        // extension emits in its `volume.info` event so the model's
        // `applyEventInPlace` overlays cleanly.
        var fields: [String: String] = ["bsd": bsd]

        guard let rawKind = desc[kDADiskDescriptionVolumeKindKey as String] as? String,
              !rawKind.isEmpty else { return }
        // DA reports the FSShortName for FSKit-managed volumes
        // ("fsext4", "fsntfs") and the legacy bsd name for
        // built-in filesystems ("msdos", "exfat", "hfs", "apfs").
        // Normalise to the canonical short form the extension emits
        // — strip a leading "fs" so the model's fsType matches across
        // both event sources.
        let fs = canonicalFsName(rawKind)
        // Filter against the same fs allow-list the model uses for
        // mount(8) enumeration. Without this, DA pumps system APFS
        // partitions (Macintosh HD, Preboot, xART, …) into the
        // sidebar — uninteresting noise that drowns the actual user
        // disks. fsTypesOfInterest is `public var` on the model so we
        // read the live value here (caller can override at runtime).
        guard attachedDisks?.fsTypesOfInterest.contains(fs) == true else {
            return
        }
        fields["fs"] = fs
        if let name = desc[kDADiskDescriptionVolumeNameKey as String] as? String,
           !name.isEmpty {
            fields["volume_name"] = name
        }
        // Volume UUID — populated for filesystems macOS knows natively
        // (apfs / hfs / exfat / msdos with UUID slot) and for FSKit
        // modules that fill `FSContainerIdentifier.uuid` on probe (our
        // ext4 + ntfs do this). May be missing on bare msdos volumes
        // without the optional Boot Sector UUID slot.
        if let uuidRef = desc[kDADiskDescriptionVolumeUUIDKey as String] {
            let uuidCF = uuidRef as! CFUUID
            if let strRef = CFUUIDCreateString(kCFAllocatorDefault, uuidCF) {
                fields["volume_uuid"] = strRef as String
            }
        }

        AppLog.shared.info(
            "DA appeared: bsd=\(bsd) fs=\(fields["fs"] ?? "?") name=\(fields["volume_name"] ?? "?") uuid=\(fields["volume_uuid"] ?? "?")"
        )

        attachedDisks?.applyExtensionEvent(kind: "volume.info", fields: fields)
    }

    private func handleDisappeared(_ disk: DADisk) {
        guard let descCF = DADiskCopyDescription(disk) else { return }
        let desc = descCF as NSDictionary
        guard let bsd = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String else {
            return
        }
        AppLog.shared.info("DA disappeared: bsd=\(bsd)")
        // No model action needed — the next refresh() poll will see
        // the BSD missing from /sbin/mount and flip the row to
        // .offline via the existing detached-row path.
    }

    /// Normalise DA's `VolumeKindKey` to the short fs name the FSKit
    /// extensions emit in their `volume.info` events.
    ///
    /// DA reports:
    ///   - `"fsext4"` / `"fsntfs"` for FSKit modules (FSShortName)
    ///   - `"msdos"` / `"exfat"` / `"hfs"` / `"apfs"` for native macOS fs
    ///   - `"ntfs"` for the legacy Apple ntfs.fs
    ///
    /// We strip a leading `fs` prefix so the FSKit forms align with what
    /// the extension self-reports (`"ext4"`, `"ntfs"`). Pass-through
    /// for everything else.
    private func canonicalFsName(_ raw: String) -> String {
        if raw.hasPrefix("fs") && raw.count > 2 {
            return String(raw.dropFirst(2))
        }
        return raw
    }
}
