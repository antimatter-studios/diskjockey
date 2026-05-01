//
// NetworkDrivesSetupView.swift — first-run welcome / folder-setup pane.
//
// Shown in the detail area when the user hasn't yet approved a folder
// for DiskJockey to drop mount symlinks into. We prefer this over a
// modal dialog because there's too much context to fit in a dialog
// cleanly, and because it gives a place to explain what DiskJockey
// is going to do before the OS security panel pops up.
//

import SwiftUI
import DiskJockeyLibrary

struct NetworkDrivesSetupView: View {
    @ObservedObject var homeAccess: HomeAccessService
    let registry: DirectMountRegistry

    @State private var isPicking = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                mainExplanation
                howItWorks
                privacyNote
                pickFolderButton
                if let err = errorMessage {
                    errorBanner(err)
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 32)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 16) {
            Image("tabler-externaldrive-connected-to-line-below")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.accentColor.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up Network Drive Mounts")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("One-time folder permission")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var mainExplanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DiskJockey creates shortcuts for each network drive you mount, so you can reach them quickly from Finder or the terminal without hunting through `~/Library/CloudStorage`.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Text("Because DiskJockey is sandboxed, macOS requires your permission before it can write into your home folder. We only need to ask once — after you pick a folder, that permission is remembered.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How it works")
                .font(.headline)

            SetupStep(
                number: "1",
                title: "You pick a folder",
                detail: "Click Choose Folder below. A standard macOS file picker opens at your home directory. Navigate to wherever you'd like your mount shortcuts to live (we suggest `~/diskjockey`, but any home subfolder is fine), or create a new one right there."
            )

            SetupStep(
                number: "2",
                title: "macOS grants DiskJockey access",
                detail: "By choosing that folder in the picker, you authorize DiskJockey to read and write inside it — nowhere else. No blanket access to your home directory."
            )

            SetupStep(
                number: "3",
                title: "DiskJockey drops symlinks as you add mounts",
                detail: "Every direct-linked network drive you add gets a symbolic link inside the folder you picked, named after the mount (lowercased, ASCII-safe). `cd` into it, drag it to your Finder sidebar, scp against it — it's a real path."
            )
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image("tabler-lock-shield")
                .foregroundStyle(.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Scoped access only")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("The permission is persisted as a security-scoped bookmark — the standard macOS pattern. If you move or delete the folder, DiskJockey asks you to pick a new one. You can always re-choose in the future.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var pickFolderButton: some View {
        // macOS' built-in tinted button styles (.borderedProminent,
        // .bordered+.tint) desaturate the accent color aggressively
        // when the window isn't key — enough that the button visually
        // disappears against a light background. Custom style below
        // paints the accent background unconditionally so the button
        // stays visible whether DiskJockey has focus or not.
        VStack(alignment: .leading, spacing: 10) {
            Button(action: pickFolder) {
                HStack(spacing: 8) {
                    if isPicking {
                        ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                    } else {
                        Image("tabler-folder-badge-plus")
                    }
                    Text("Choose Folder…")
                }
                .frame(minWidth: 180)
            }
            .buttonStyle(ProminentActionButtonStyle())
            .disabled(isPicking)

            Text("You can skip this for now — DiskJockey will ask again the first time you create a network mount.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image("tabler-exclamationmark-triangle-fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
            Spacer()
            Button("Dismiss") { errorMessage = nil }
                .buttonStyle(.borderless)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yellow.opacity(0.1))
        )
    }

    // MARK: - Action

    private func pickFolder() {
        isPicking = true
        errorMessage = nil
        // NSOpenPanel is synchronous (modal) on macOS. No Task hop
        // needed; the UI just re-renders once `hasFolder` flips and
        // ContentView swaps us out.
        do {
            _ = try homeAccess.pickFolder()
            // Any mounts that were created before the folder was
            // picked are now eligible for their own symlinks. Kick
            // the backfill off asynchronously so we don't block the
            // UI swap-out from the setup pane.
            Task { await registry.backfillSymlinks() }
        } catch HomeAccessError.userCancelled {
            // Silent — user chose not to pick right now.
        } catch {
            errorMessage = error.localizedDescription
        }
        isPicking = false
    }
}

// MARK: - Helpers

/// Prominent action button that always paints an accent-coloured
/// background — unlike the built-in `.borderedProminent` which
/// desaturates so aggressively when the parent window isn't key
/// that the button visually disappears against a light background.
/// Same feel as `.borderedProminent` (rounded rect, tinted), no
/// focus dependency.
struct ProminentActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor)
                    .opacity(configuration.isPressed ? 0.80 : 1.0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SetupStep: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.subheadline.monospaced())
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
