# DiskJockey SwiftUI Prototype

This is a minimal SwiftUI-based macOS app that shows a sidebar of plugins and details for the selected plugin. No AppKit or storyboard code is required.

## Files
- `SwiftUIPluginListApp.swift`: App entry point (replaces AppDelegate)
- `ContentView.swift`: Main UI (sidebar + detail panel)
- `PluginModel.swift`: ObservableObject for plugin data

## How to Run
1. In Xcode, set the app entry point to `SwiftUIPluginListApp` (delete Main.storyboard if needed).
2. Build and run.
3. You will see a sidebar with sample plugins and a detail panel.

## Next Steps
- Integrate real plugin data from backend/IPC.
- Remove old AppKit files (AppDelegate.swift, SettingsViewController.swift, Main.storyboard, etc) for a pure SwiftUI app.
- Style and expand as needed.

---

If you want to connect to your backend, update `PluginModel` to fetch plugins via your IPC/MessageServer logic and publish them to the UI.
