//
// SymlinkManager.swift — creates & removes `$HOME/DiskJockey/<name>`
// symlinks pointing at the user-visible URL of a FileProvider domain.
// CLI tools (and Finder shortcuts) can then navigate to a stable path
// without having to know the volatile CloudStorage location.
//
// Sandbox note: writing symlinks under `$HOME` from a sandboxed app is
// NOT permitted by default. `com.apple.security.temporary-exception.
// files.home-relative-path.read-write` or `user-selected.read-write`
// can open the door, but the simplest path for a POC is to disable
// sandboxing on this target (or rely on the user-selected bookmark
// flow). For now we attempt `FileManager.createSymbolicLink` and
// surface any failure so the caller can decide whether to keep going.
// See `SymlinkError.sandboxBlocked` for the expected failure mode.
//

import Foundation
import DiskJockeyLibrary

public enum SymlinkError: Error, LocalizedError {
    case homeUnavailable
    case sandboxBlocked(underlying: Error)
    case ioFailed(String)

    public var errorDescription: String? {
        switch self {
        case .homeUnavailable:
            return "Could not determine the user's home directory."
        case .sandboxBlocked(let underlying):
            return "The app sandbox blocked symlink creation: \(underlying.localizedDescription)"
        case .ioFailed(let msg):
            return "Symlink I/O failed: \(msg)"
        }
    }
}

@MainActor
public final class SymlinkManager {
    /// Directory under `$HOME` that holds all DiskJockey symlinks.
    /// Created lazily on first write. Lowercase by convention — the
    /// symlink tree is primarily a shell-friendly affordance, and
    /// $HOME/diskjockey/ reads + tabs more naturally than an
    /// uppercased one.
    public static let dirName = "diskjockey"

    public init() {}

    /// The parent directory (`~/DiskJockey`). We resolve this via
    /// `FileManager.default.homeDirectoryForCurrentUser` rather than
    /// `NSHomeDirectory()` because the latter returns the sandbox
    /// container inside an app-sandbox build — and we explicitly want
    /// the real `$HOME` so CLI tools outside the sandbox can see the
    /// symlinks.
    public var rootDirectory: URL {
        // `homeDirectoryForCurrentUser` returns the REAL home even
        // inside a sandboxed process (though actually reading/writing
        // it may still be blocked by the sandbox).
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(Self.dirName, isDirectory: true)
    }

    /// Ensure `~/DiskJockey` exists. Idempotent. Throws if `$HOME` is
    /// not discoverable or the sandbox denies the write.
    @discardableResult
    public func ensureRootDirectory() throws -> URL {
        let dir = rootDirectory
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
            if isDir.boolValue { return dir }
            throw SymlinkError.ioFailed("\(dir.path) exists but is not a directory")
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            // Sandbox deny = "Operation not permitted" (EPERM) or
            // NSCocoaErrorDomain 513 depending on the Cocoa layer.
            throw SymlinkError.sandboxBlocked(underlying: error)
        }
        return dir
    }

    /// Create (or replace) `~/DiskJockey/<name>` pointing at `target`.
    /// If a symlink with that name already exists it is removed first.
    /// Regular files/directories at that path are LEFT ALONE to avoid
    /// clobbering user data — we throw instead.
    public func createSymlink(name: String, target: URL) throws -> URL {
        let root = try ensureRootDirectory()
        let linkURL = root.appendingPathComponent(name)
        let fm = FileManager.default

        // If there's something at the path already, allow replacing
        // only if it's a symbolic link (our own prior placement).
        if fm.fileExists(atPath: linkURL.path) || symlinkExists(at: linkURL) {
            let attrs = try? fm.attributesOfItem(atPath: linkURL.path)
            let type = attrs?[.type] as? FileAttributeType
            if type == .typeSymbolicLink || symlinkExists(at: linkURL) {
                try? fm.removeItem(at: linkURL)
            } else {
                throw SymlinkError.ioFailed(
                    "Path \(linkURL.path) already exists and is not a symlink."
                )
            }
        }

        do {
            try fm.createSymbolicLink(at: linkURL, withDestinationURL: target)
        } catch {
            throw SymlinkError.sandboxBlocked(underlying: error)
        }
        return linkURL
    }

    /// Remove `~/DiskJockey/<name>` if present. No-op if missing.
    public func removeSymlink(name: String) throws {
        let linkURL = rootDirectory.appendingPathComponent(name)
        if symlinkExists(at: linkURL) {
            do {
                try FileManager.default.removeItem(at: linkURL)
            } catch {
                throw SymlinkError.ioFailed(error.localizedDescription)
            }
        }
    }

    /// Walk `~/DiskJockey` and delete any symlinks whose targets no
    /// longer resolve. Called on launch to clean up after killed
    /// extensions / deleted domains.
    public func sweepDangling() {
        let fm = FileManager.default
        let dir = rootDirectory
        guard fm.fileExists(atPath: dir.path) else { return }
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            guard symlinkExists(at: entry) else { continue }
            // Resolve the symlink and check its target.
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

    /// True if `url` is a symbolic link (regardless of whether its
    /// target exists). `FileManager.fileExists(atPath:)` follows
    /// symlinks, which is why we need this helper.
    private func symlinkExists(at url: URL) -> Bool {
        var stat = stat()
        return lstat(url.path, &stat) == 0 && (stat.st_mode & S_IFMT) == S_IFLNK
    }

    /// Pick a symlink filename that doesn't collide with anything
    /// already in `~/diskjockey`. If "my_mount" is taken we try
    /// "my_mount_2", "my_mount_3", ... TODO: This is in-process only —
    /// two separate DiskJockey instances could race. Good enough for
    /// a POC.
    ///
    /// The input is ASCII-folded + snake-cased first so shell tools
    /// don't need to deal with Unicode / spaces in the path.
    public func uniqueName(preferred: String) -> String {
        let root = rootDirectory
        let fm = FileManager.default
        let base = Self.snakeCaseASCII(preferred)
        var candidate = base
        var n = 2
        while fm.fileExists(atPath: root.appendingPathComponent(candidate).path)
                || symlinkExists(at: root.appendingPathComponent(candidate)) {
            candidate = "\(base)_\(n)"
            n += 1
            if n > 999 { break } // don't spin forever
        }
        return candidate
    }

    /// Normalize a mount display name into a safe, shell-friendly
    /// directory name: ASCII-fold Unicode (`Café` → `Cafe`), lowercase,
    /// replace runs of non-alphanumerics with a single underscore,
    /// trim leading/trailing underscores. Empty input → "mount".
    static func snakeCaseASCII(_ s: String) -> String {
        // ASCII-fold: Unicode NFD + strip non-ASCII code points. Keeps
        // "Café" recognizable ("cafe") rather than erasing it entirely.
        let folded = s.applyingTransform(.toLatin, reverse: false)
            .flatMap { s in s.applyingTransform(.stripDiacritics, reverse: false) }
            ?? s
        let lower = folded.lowercased()

        var out = ""
        var lastWasSep = true // lead with no separator
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
