//
// MIT License — see LICENSE
//
// VolumeUnmounter.swift — unmount a mounted volume through DiskArbitration.
//
// WHY NOT `diskutil unmount` (#166). diskutil hands mount and unmount to
// storagekitd, and StorageKit does not know FSKit file systems: it lists an
// ext4 volume as "File System: None" and fails without asking
// DiskArbitration. Measured 2026-10-07 on macOS 26.4, with a volume mounted
// by our EXT4 extension at /Volumes/testvolume:
//
//     diskutil unmount /Volumes/testvolume        -> failed, StorageKit 119
//     diskutil unmount force /Volumes/testvolume  -> failed, StorageKit 119
//     DADiskUnmount on the same volume            -> unmounted
//
// `diskutil mount` fails the same way (StorageKit 124, "Disk is not
// mountable") where `DADiskMount` succeeds, which is why
// DiskArbitrationService mounts through DA too.
//
// The one guard here that matters more than the DA call: the path must BE a
// mount point. `DADiskCreateFromVolumePath` resolves any path to the volume
// that contains it, so a stale row whose mount point is now an ordinary
// directory under /Volumes would otherwise unmount the boot volume's data
// volume. `mountPoint(of:)` refuses that before DA is involved.
//

import Foundation
import DiskArbitration

public enum VolumeUnmounter {

    /// `path`, with symlinks resolved, if it is the root of a mounted file
    /// system; nil if it is anything else (an ordinary directory, a file,
    /// a path that does not exist).
    ///
    /// The comparison is against `statfs`'s `f_mntonname` for the same
    /// path, so `/tmp` resolves to `/private/tmp` first and a firmlinked
    /// directory compares by its real location.
    public static func mountPoint(of path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        var fs = statfs()
        guard statfs(resolved, &fs) == 0 else { return nil }
        let real = String(cString: resolved)
        let mountedOn = withUnsafeBytes(of: &fs.f_mntonname) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return real == mountedOn ? real : nil
    }

    /// Unmount the volume mounted at `mountPath` via `DADiskUnmount`.
    ///
    /// `completion` gets nil when DiskArbitration reports success. It gets
    /// an `NSError` in the DiskArbitration domain, carrying the dissenter's
    /// status and status string, when DA refuses (EBUSY from an open file is
    /// the usual one). A `POSIXError(.EINVAL)` comes back synchronously, and
    /// DA is never called, when `mountPath` is not a mount point. A
    /// `POSIXError(.ENODEV)` comes back when DA has no disk for the path.
    ///
    /// `force` passes `kDADiskUnmountOptionForce`, for clearing a mount whose
    /// device has already gone.
    ///
    /// `completion` runs on an internal serial queue; hop to the main actor
    /// yourself if the caller is UI.
    public static func unmount(
        mountPath: String,
        force: Bool = false,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        guard let root = mountPoint(of: mountPath) else {
            completion(POSIXError(.EINVAL, userInfo: [
                NSLocalizedDescriptionKey: "\(mountPath) is not a mount point, so there is nothing to unmount there."]))
            return
        }
        let queue = DispatchQueue(label: "com.antimatterstudios.diskjockey.unmount")
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            completion(POSIXError(.ENOMEM))
            return
        }
        DASessionSetDispatchQueue(session, queue)
        let url = URL(fileURLWithPath: root, isDirectory: true) as CFURL
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url) else {
            DASessionSetDispatchQueue(session, nil)
            completion(POSIXError(.ENODEV, userInfo: [
                NSLocalizedDescriptionKey: "DiskArbitration has no disk for \(root)."]))
            return
        }

        // The box keeps the session scheduled until DA answers; DA calls the
        // callback exactly once per request.
        final class Pending {
            let session: DASession
            let completion: @Sendable (Error?) -> Void
            init(session: DASession, completion: @escaping @Sendable (Error?) -> Void) {
                self.session = session
                self.completion = completion
            }
        }
        let ctx = Unmanaged.passRetained(Pending(session: session, completion: completion)).toOpaque()
        let options = DADiskUnmountOptions(force ? kDADiskUnmountOptionForce : kDADiskUnmountOptionDefault)
        DADiskUnmount(disk, options, { _, dissenter, ctx in
            guard let ctx = ctx else { return }
            let pending = Unmanaged<Pending>.fromOpaque(ctx).takeRetainedValue()
            var error: Error?
            if let dissenter = dissenter {
                let status = DADissenterGetStatus(dissenter)
                let reason = (DADissenterGetStatusString(dissenter) as String?)
                    ?? String(format: "DiskArbitration status 0x%08X", UInt32(bitPattern: status))
                error = NSError(domain: "DiskArbitration", code: Int(status),
                                userInfo: [NSLocalizedDescriptionKey: reason])
            }
            DASessionSetDispatchQueue(pending.session, nil)
            pending.completion(error)
        }, ctx)
    }
}
