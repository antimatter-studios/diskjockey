//
// ExtensionsView.swift — in-app management for DiskJockey's bundled
// extensions (DiskJockeyEXT4, DiskJockeyNTFS, DiskJockeyFileProvider).
//
// Wraps `EXAppExtensionBrowserViewController` so the user sees + toggles
// all of DiskJockey's extensions here instead of navigating to System
// Settings → Login Items & Extensions. The browser VC is scoped to the
// host app's extensions only, so the list reads as "DiskJockey's
// extensions" even though each row is a separate OS-level approval
// record.
//
// Requires macOS 13+ (API availability of EXAppExtensionBrowserViewController).
//

import AppKit
import ExtensionKit
import SwiftUI

struct ExtensionsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Extensions")
                    .font(.title2.weight(.semibold))
                Text("DiskJockey ships multiple extensions — one per filesystem "
                    + "type (ext4, NTFS) and one for network drives. Enable the "
                    + "ones you want macOS to use; changes take effect the next "
                    + "time a matching disk is inserted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            ExtensionBrowser()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// `NSViewControllerRepresentable` wrapper around
/// `EXAppExtensionBrowserViewController`. The VC is out-of-process — it
/// hosts Apple's extension-management UI via XPC — so there's nothing
/// for us to configure beyond making it.
private struct ExtensionBrowser: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> EXAppExtensionBrowserViewController {
        EXAppExtensionBrowserViewController()
    }

    func updateNSViewController(_ nsViewController: EXAppExtensionBrowserViewController,
                                context: Context) {}
}
