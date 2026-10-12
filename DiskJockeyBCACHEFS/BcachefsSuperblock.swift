/*
 * BcachefsSuperblock.swift — recognising a bcachefs device by its primary
 * superblock, for the probe.
 *
 * The superblock is at byte 4096 (sector 8). Within it, the magic is the
 * 16 bytes at 0x18, the internal UUID at 0x28, the user-visible UUID at
 * 0x38 and the label the 32 bytes at 0x48, NUL-padded (rust-fs-bcachefs's
 * superblock layout, src/superblock.rs). Sixteen bytes of magic at a fixed
 * place are what keep the probe from claiming another filesystem.
 *
 * MIT License — see LICENSE
 */

import Foundation

struct BcachefsSuperblock: Equatable {
    static let offset = 4096
    static let magic: [UInt8] = [
        0xc6, 0x85, 0x73, 0xf6, 0x66, 0xce, 0x90, 0xa9,
        0xd9, 0x6a, 0x60, 0xcf, 0x80, 0x3d, 0xf7, 0xef,
    ]
    /// How much of the device the probe must read: through the label.
    static let probeLength = offset + 0x68

    /// The user-visible UUID, or the internal one where that is all zero.
    let containerUUID: UUID
    /// The label, NUL padding removed; empty when there is none.
    let label: String

    /// Nil unless `bytes`, the device from its byte 0, holds a bcachefs
    /// superblock's magic at its place.
    init?(device bytes: [UInt8]) {
        let base = Self.offset
        guard bytes.count >= Self.probeLength,
              Array(bytes[(base + 0x18)..<(base + 0x28)]) == Self.magic else { return nil }
        let internalUUID = Array(bytes[(base + 0x28)..<(base + 0x38)])
        let userUUID = Array(bytes[(base + 0x38)..<(base + 0x48)])
        let chosen = userUUID.allSatisfy { $0 == 0 } ? internalUUID : userUUID
        containerUUID = chosen.withUnsafeBytes { raw in
            NSUUID(uuidBytes: raw.bindMemory(to: UInt8.self).baseAddress!) as UUID
        }
        let field = bytes[(base + 0x48)..<(base + 0x68)]
        label = String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
    }
}
