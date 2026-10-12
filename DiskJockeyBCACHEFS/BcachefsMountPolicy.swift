/*
 * BcachefsMountPolicy.swift — whether a bcachefs mount writes.
 *
 * Read-write is the default: a writable device mounts read-write with no
 * opt-in. A mount is read-only only when the device cannot be written or
 * the mount asks for it (`ro`, FSKit's `--rdonly`, `rdonly`). This is a
 * decision, not a probe of the driver: a filesystem the driver will not
 * write (one not cleanly unmounted, say) still mounts read-write, and each
 * write answers the driver's own errno for the refusal.
 *
 * MIT License — see LICENSE
 */

import Foundation

enum BcachefsMountPolicy: Equatable {
    case readOnly
    case readWrite

    /// The mount options that ask for a read-only mount, however FSKit or
    /// mount(8) spells them.
    static let readOnlyFlags: Set<String> = ["ro", "rdonly", "--rdonly", "-r"]

    /// The policy for a device and the task's options. Options arrive as
    /// separate arguments or comma-joined lists (`-o ro,noatime`).
    init(deviceIsWritable: Bool, options: [String]) {
        self = deviceIsWritable && !Self.asksReadOnly(options) ? .readWrite : .readOnly
    }

    static func asksReadOnly(_ options: [String]) -> Bool {
        options
            .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            .contains { readOnlyFlags.contains($0) }
    }
}
