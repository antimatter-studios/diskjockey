//
// SymlinkManager.swift — creates & removes `$HOME/diskjockey/<name>`
// symlinks pointing at the user-visible URL of a FileProvider domain.
// CLI tools (and Finder shortcuts) can then navigate to a stable path
// without having to know the volatile CloudStorage location.
//
// The host app is sandboxed (App Store requirement). We reach $HOME
// via a one-time user-approved NSOpenPanel + security-scoped bookmark,
// managed by `HomeAccessService`. Every file-system op in this class
// runs inside `access.withAccess { url in … }` so the bookmark's
// startAccessing/stopAccessing lifecycle is always balanced.
//

import Foundation
import DiskJockeyLibrary

public enum SymlinkError: Error, LocalizedError {
    case accessDenied(underlying: Error)
    case ioFailed(String)
    case pathCollision(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied(let underlying):
            return "Could not access the DiskJockey folder: \(underlying.localizedDescription)"
        case .ioFailed(let msg):
            return "Symlink I/O failed: \(msg)"
        case .pathCollision(let msg):
            return msg
        }
    }
}

@MainActor
public final class SymlinkManager {
    private let access: HomeAccessService

    public init(access: HomeAccessService) {
        self.access = access
    }

    /// Ensure the user-selected DiskJockey folder exists and return its
    /// path inside a security-scoped-resource block. Throws if the user
    /// cancels the picker.
    @discardableResult
    public func ensureRootDirectory() throws -> URL {
        return try access.withAccess { url in
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return url
        }
    }

    /// Create (or replace) `$HOME/diskjockey/<name>` pointing at
    /// `target`. If a symlink with that name already exists it is
    /// removed first. Non-symlink files/directories at that path are
    /// LEFT ALONE to avoid clobbering user data — we throw instead.
    @discardableResult
    public func createSymlink(name: String, target: URL) throws -> URL {
        return try access.withAccess { root in
            let fm = FileManager.default
            if !fm.fileExists(atPath: root.path) {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
            }
            let linkURL = root.appendingPathComponent(name)

            if fm.fileExists(atPath: linkURL.path) || symlinkExists(at: linkURL) {
                let attrs = try? fm.attributesOfItem(atPath: linkURL.path)
                let type = attrs?[.type] as? FileAttributeType
                if type == .typeSymbolicLink || symlinkExists(at: linkURL) {
                    try? fm.removeItem(at: linkURL)
                } else {
                    throw SymlinkError.pathCollision(
                        "Path \(linkURL.path) already exists and is not a symlink."
                    )
                }
            }
            do {
                try fm.createSymbolicLink(at: linkURL, withDestinationURL: target)
            } catch {
                throw SymlinkError.accessDenied(underlying: error)
            }
            return linkURL
        }
    }

    /// Remove `$HOME/diskjockey/<name>` if present. No-op if missing.
    public func removeSymlink(name: String) throws {
        try access.withAccess { root in
            let linkURL = root.appendingPathComponent(name)
            if symlinkExists(at: linkURL) {
                do {
                    try FileManager.default.removeItem(at: linkURL)
                } catch {
                    throw SymlinkError.ioFailed(error.localizedDescription)
                }
            }
        }
    }

    /// Walk `$HOME/diskjockey` and delete any symlinks whose targets
    /// no longer resolve. Swallows the user-cancelled-panel case —
    /// on app launch we don't want to force a prompt before the user
    /// has asked for anything.
    public func sweepDangling() {
        do {
            try access.withAccess { root in
                let fm = FileManager.default
                guard fm.fileExists(atPath: root.path) else { return }
                guard let entries = try? fm.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { return }
                for entry in entries {
                    guard symlinkExists(at: entry) else { continue }
                    guard let dest = try? fm.destinationOfSymbolicLink(atPath: entry.path) else {
                        try? fm.removeItem(at: entry)
                        continue
                    }
                    let destURL: URL
                    if (dest as NSString).isAbsolutePath {
                        destURL = URL(fileURLWithPath: dest)
                    } else {
                        destURL = entry.deletingLastPathComponent()
                            .appendingPathComponent(dest)
                    }
                    if !fm.fileExists(atPath: destURL.path) {
                        try? fm.removeItem(at: entry)
                    }
                }
            }
        } catch {
            // User hasn't approved a folder yet (first launch, no
            // direct mounts). That's fine — nothing to sweep.
        }
    }

    /// True if `url` is a symbolic link (regardless of whether its
    /// target exists). `FileManager.fileExists(atPath:)` follows
    /// symlinks, which is why we need this helper.
    private func symlinkExists(at url: URL) -> Bool {
        var stat = stat()
        return lstat(url.path, &stat) == 0 && (stat.st_mode & S_IFMT) == S_IFLNK
    }

    /// Pick a symlink filename that doesn't collide with anything
    /// already in `$HOME/diskjockey`. ASCII-folds + snake-cases so
    /// shell tools don't need to deal with Unicode / spaces.
    public func uniqueName(preferred: String) -> String {
        let base = Self.snakeCaseASCII(preferred)
        // Try to resolve the folder; if the user hasn't picked it yet
        // we still return a sensible name (collision check happens
        // again at createSymlink time).
        let existing: Set<String> = (try? access.withAccess { root in
            let fm = FileManager.default
            let entries = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            return Set(entries)
        }) ?? []
        var candidate = base
        var n = 2
        while existing.contains(candidate) {
            candidate = "\(base)_\(n)"
            n += 1
            if n > 999 { break }
        }
        return candidate
    }

    /// Normalize a mount display name into a safe, shell-friendly
    /// directory name: ASCII-fold Unicode (`Café` → `Cafe`), lowercase,
    /// replace runs of non-alphanumerics with a single underscore,
    /// trim leading/trailing underscores. Empty input → "mount".
    static func snakeCaseASCII(_ s: String) -> String {
        let folded = s.applyingTransform(.toLatin, reverse: false)
            .flatMap { s in s.applyingTransform(.stripDiacritics, reverse: false) }
            ?? s
        let lower = folded.lowercased()

        var out = ""
        var lastWasSep = true
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSep = false
            } else if !lastWasSep {
                out.append("_")
                lastWasSep = true
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        return out.isEmpty ? "mount" : out
    }
}
