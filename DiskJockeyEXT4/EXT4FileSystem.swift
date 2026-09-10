/*
 * EXT4FileSystem.swift — FSKit `FSUnaryFileSystem` principal class
 * for the ext4 extension. Class skeleton only: the FSKit pipeline
 * methods are spread across sibling files in this folder by concern,
 * and the FFI bridge contexts live in DiskJockeyLibrary so other
 * filesystems can reuse them.
 *
 *   EXT4Probe.swift                            — `probeResource` / `probeFileResource` / container detection
 *   EXT4Load.swift                             — `loadResource` / `unloadResource` / fs_core handle chain
 *   EXT4Maintenance.swift                      — `startCheck` / `startFormat` + `FsckProgressTracker`
 *   DiskJockeyLibrary/DeviceContexts.swift     — FFI bridge contexts (`DeviceReadable`,
 *                                                `BlockDeviceContext`, `FileDeviceContext`)
 *                                                shared across DJ filesystems
 *
 * What stays here:
 *   • The class declaration + `MountedResource` struct + statics
 *     (`mountedResources` registry, `watchdog`, enter/exit/scheduleWatchdog).
 *   • `init()` (which kicks off the per-process `RepairXPCService`).
 *   • Pure utility helpers — `taskOption` (mount-arg parsing) and the
 *     format-display helpers used by the `volume.info` event emitter
 *     (`formatCreatorOS`, `formatState`, `formatErrorsBehavior`,
 *     `formatFeatureFlags` + `FeatureKind`).
 *   • The trailing `MountableFileSystem` conformance extension.
 */

import FSKit
import Foundation
import os
import DiskJockeyLibrary

@objc(EXT4FileSystem)
final class EXT4FileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    /// FSKit's `startCheck(task:options:)` hands us no resource handle —
    /// only an `FSTask` + `FSTaskOptions` (see FSResource.h ~L442). To
    /// route fsck back to the right mounted volume's backend we register
    /// `(bsdName, EXT4Backend)` keyed by resource identity at
    /// `loadResource` time and look it up here. Cleared on
    /// `unloadResource`.
    ///
    /// Keyed by `ObjectIdentifier(FSResource)` — FSKit hands us the same
    /// FSResource instance for the lifetime of the mount, so the
    /// in-process pointer is a stable, unique handle. We don't need
    /// `FSResource.identifier` (UUID) because we never persist this map.
    /// Guarded by an unfair lock so `startCheck` can read it without
    /// awaiting an actor.
    struct MountedResource: DiskJockeyLibrary.MountedResource {
        let bsdName: String
        let backend: EXT4Backend
        /// Retained `BlockDeviceContext` pointer for block-device mounts;
        /// nil for file-backed (FSPathURLResource) mounts where startFormat
        /// is not supported. Used by startFormat to rebuild the blockdev cfg.
        let contextPtr: UnsafeMutableRawPointer?
        /// Cooperative tri-state mutex coordinating verify (`startCheck`)
        /// and repair (`RepairXPCService`) so both can't run on the
        /// same mounted volume concurrently. Default `.idle` ⇒
        /// filesystem is available for normal operations. See
        /// `OperationLock` for the contract.
        let opLock: OperationLock
    }
    static let mountedResources = MountedResourceRegistry<MountedResource>()

    /// Thin wrappers preserved so call sites (this file, EXT4Maintenance,
    /// RepairXPCService) do not need to know where the watchdog lives.
    /// See EXT4Watchdog for the watchdog itself.
    static func enterOperation() { EXT4Watchdog.enter() }
    static func exitOperation() { EXT4Watchdog.leave() }

    override init() {
        super.init()
        // One mach-service listener per process — guarded inside start().
        // Vends in-process repair to the host app via NSXPCConnection;
        // see RepairXPCService for the rationale.
        RepairXPCService.shared.start()
    }

    // MARK: - Utilities

    /// Parse a `key=value` mount option out of FSTaskOptions.taskOptions.
    /// `mount -F -t ext4 -o foo=1,bar=2 …` may surface either as one
    /// comma-separated string or as multiple entries depending on FSKit
    /// version; we handle both by splitting each entry on commas.
    static func taskOption<T>(_ name: String,
                              from argv: [String],
                              parser: (String) -> T?) -> T? {
        for raw in argv {
            for pair in raw.split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 && kv[0] == name {
                    if let v = parser(kv[1]) { return v }
                }
            }
        }
        return nil
    }

    /// Render the `s_creator_os` field. The ext4 spec defines five
    /// values; anything else gets the raw number so the user can look
    /// it up in `ext4.h` if it ever appears in the wild.
    static func formatCreatorOS(_ raw: UInt32) -> String {
        switch raw {
        case 0: return "Linux"
        case 1: return "Hurd"
        case 2: return "Masix"
        case 3: return "FreeBSD"
        case 4: return "Lites"
        default: return "unknown (\(raw))"
        }
    }

    /// Render `s_state` as a comma-separated bit list. Fresh filesystems
    /// read as "valid"; a kernel that detected errors leaves the
    /// `errors` bit set even after a remount.
    static func formatState(_ raw: UInt16) -> String {
        var parts: [String] = []
        if raw & 0x0001 != 0 { parts.append("valid") }
        if raw & 0x0002 != 0 { parts.append("errors") }
        if raw & 0x0004 != 0 { parts.append("orphan_recovery") }
        if parts.isEmpty { return "unknown (\(raw))" }
        return parts.joined(separator: ", ")
    }

    /// Render `s_errors`. The kernel uses this to decide what to do
    /// when it detects metadata corruption mid-operation.
    static func formatErrorsBehavior(_ raw: UInt16) -> String {
        switch raw {
        case 1: return "continue"
        case 2: return "remount read-only"
        case 3: return "panic"
        default: return "unknown (\(raw))"
        }
    }

    /// Pretty-print the three feature bitmaps as a comma-separated
    /// list of names. Caller passes the field tag ("compat",
    /// "incompat", "ro_compat") so we know which name table to use.
    /// Unknown bits surface as `bit-<n>` so nothing is silently lost.
    static func formatFeatureFlags(_ raw: UInt32, kind: FeatureKind) -> String {
        let names = kind.bitNames
        var out: [String] = []
        for i in 0..<32 where (raw & (UInt32(1) << i)) != 0 {
            if let n = names[i] { out.append(n) }
            else { out.append("bit-\(i)") }
        }
        return out.isEmpty ? "(none)" : out.joined(separator: ", ")
    }

    enum FeatureKind {
        case compat, incompat, roCompat

        /// Mapping from bit position → spec-defined feature name.
        /// Sourced from `linux/fs/ext4/ext4.h`; bits not yet defined
        /// stay nil and surface as `bit-<n>` to the user.
        var bitNames: [Int: String] {
            switch self {
            case .compat: return [
                0: "dir_prealloc", 1: "imagic_inodes", 2: "has_journal",
                3: "ext_attr", 4: "resize_inode", 5: "dir_index",
                6: "lazy_bg", 7: "exclude_inode", 8: "exclude_bitmap",
                9: "sparse_super2",
            ]
            case .incompat: return [
                0: "compression", 1: "filetype", 2: "recover",
                3: "journal_dev", 4: "meta_bg", 6: "extents",
                7: "64bit", 8: "mmp", 9: "flex_bg",
                10: "ea_inode", 12: "dirdata", 13: "csum_seed",
                14: "largedir", 15: "inline_data", 16: "encrypt",
                17: "casefold",
            ]
            case .roCompat: return [
                0: "sparse_super", 1: "large_file", 2: "btree_dir",
                3: "huge_file", 4: "gdt_csum", 5: "dir_nlink",
                6: "extra_isize", 7: "quota", 8: "bigalloc",
                9: "metadata_csum", 10: "replica", 11: "readonly",
                12: "project", 13: "verity", 14: "orphan_file",
            ]
            }
        }
    }
}

// MARK: - MountableFileSystem conformance

/// Declares this extension as a DiskJockey FSKit filesystem so the
/// shared registry surface (`MountedResourceRegistry`) is reachable
/// generically. The associated `Resource` type is inferred from the
/// `static let mountedResources` declaration above.
extension EXT4FileSystem: MountableFileSystem {}
