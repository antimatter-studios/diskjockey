//
// HomeAccessService.swift — user-approved write access to ~/diskjockey
// from a sandboxed host app.
//
// The sandbox denies arbitrary writes under `$HOME`. The App-Store-safe
// workaround is a security-scoped bookmark: show an NSOpenPanel once,
// let the user pick/create the folder under `$HOME`, persist a
// security-scoped bookmark, and resolve + startAccessingSecurityScopedResource
// around every subsequent write.
//
// This service owns exactly one bookmark — the one for the root symlink
// directory. SymlinkManager calls `withAccess { url in … }` for every
// symlink op and we take care of starting / stopping the scoped access.
//
// Lifecycle:
//   • First call to withAccess: if no bookmark is saved, `NSOpenPanel`
//     runs modally; the user approves the folder and we persist a
//     security-scoped bookmark to UserDefaults.
//   • Subsequent calls: resolve the bookmark, start access, invoke the
//     caller's closure, stop access.
//   • If the bookmark has become stale (user moved/renamed the folder),
//     we re-prompt once and save the new one.
//

import Foundation
import AppKit

public enum HomeAccessError: Error, LocalizedError {
    /// No folder has been picked yet. Caller should surface the
    /// getting-started view rather than silently prompting.
    case noBookmark
    case userCancelled
    case bookmarkResolveFailed(Error?)
    case startAccessFailed
    case ioFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noBookmark:
            return "No DiskJockey folder has been chosen yet. Use the 'Choose Folder…' button to pick one."
        case .userCancelled:
            return "You need to pick (or create) the DiskJockey folder to continue."
        case .bookmarkResolveFailed(let e):
            return "Couldn't resolve the saved DiskJockey folder bookmark: \(e?.localizedDescription ?? "unknown")."
        case .startAccessFailed:
            return "The sandbox denied access to the DiskJockey folder bookmark."
        case .ioFailed(let msg):
            return "DiskJockey folder I/O failed: \(msg)"
        }
    }
}

@MainActor
public final class HomeAccessService: ObservableObject {
    private static let bookmarkKey = "DiskJockey.HomeBookmark.v1"
    /// Name we suggest for the directory in the open panel. The user
    /// is free to create a differently-named folder; the bookmark
    /// records whatever they pick.
    private static let suggestedFolderName = "diskjockey"

    /// Observed by the welcome view so the UI flips out of the
    /// "pick a folder" state the moment the user grants access.
    @Published public private(set) var hasFolder: Bool

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasFolder = defaults.data(forKey: Self.bookmarkKey) != nil
    }

    /// Resolve the existing bookmark, start scoped access, invoke
    /// `body` with the resolved URL, stop access on return.
    /// Throws `.noBookmark` if the user hasn't picked a folder yet —
    /// callers should not auto-prompt; that decision lives in the UI
    /// (the Setup pane's explicit "Choose Folder" button).
    public func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        let url = try resolve()
        guard url.startAccessingSecurityScopedResource() else {
            throw HomeAccessError.startAccessFailed
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try body(url)
    }

    /// Forget the current bookmark so the next `withAccess` re-prompts.
    public func forget() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        hasFolder = false
    }

    /// Run the picker immediately, regardless of any existing bookmark.
    /// Used by the welcome view's "Choose Folder" button so the user
    /// opts in explicitly rather than on first symlink demand.
    @discardableResult
    public func pickFolder() throws -> URL {
        let url = try promptUser()
        return url
    }

    // MARK: - Private

    /// Resolve the stored bookmark. Throws `.noBookmark` if nothing
    /// is stored, or if what's stored is stale / points at a missing
    /// path — never prompts on its own. The UI is responsible for
    /// recovering by calling `pickFolder()`.
    private func resolve() throws -> URL {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else {
            throw HomeAccessError.noBookmark
        }
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            // Stored bookmark is corrupt — forget it so the UI drops
            // back into the pick-folder state.
            forget()
            throw HomeAccessError.bookmarkResolveFailed(error)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            // User moved / deleted the folder since last launch.
            forget()
            throw HomeAccessError.noBookmark
        }
        if stale {
            try? saveBookmark(for: url)
        }
        return url
    }

    private func promptUser() throws -> URL {
        let panel = NSOpenPanel()
        panel.title = "Please choose shortcut folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        // NSOpenPanel inside a sandboxed app still resolves $HOME
        // correctly — the sandbox only gates *writes*, and NSOpenPanel
        // operates with a broader entitlement.
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.nameFieldStringValue = Self.suggestedFolderName

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            throw HomeAccessError.userCancelled
        }
        try saveBookmark(for: url)
        return url
    }

    private func saveBookmark(for url: URL) throws {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: Self.bookmarkKey)
            hasFolder = true
        } catch {
            throw HomeAccessError.ioFailed("could not encode bookmark: \(error.localizedDescription)")
        }
    }

    /// Resolved path to the user-picked folder (without starting
    /// scoped access). For display purposes only — to actually read
    /// or write there, go through `withAccess`.
    public var resolvedPath: String? {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ).path
    }
}
