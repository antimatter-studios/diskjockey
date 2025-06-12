import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sidebarModel: SidebarModel
    @EnvironmentObject var pluginModel: PluginModel
    @StateObject var mountModel = MountModel()

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebarModel.selectedItem) {
                NavigationLink(value: SidebarItem.about) {
                    Label("About", systemImage: "info.circle")
                }
                NavigationLink(value: SidebarItem.mounts) {
                    Label("Mounts", systemImage: "externaldrive")
                }
                NavigationLink(value: SidebarItem.plugins) {
                    Label("Plugins", systemImage: "puzzlepiece.extension")
                }
                NavigationLink(value: SidebarItem.quit) {
                    Label("Quit", systemImage: "power")
                }
            }
            .navigationTitle("Disk Jockey")
        } detail: {
            switch sidebarModel.selectedItem {
            case .about:
                AboutView()
            case .mounts:
                MountView()
                    .environmentObject(mountModel)
                    .environmentObject(pluginModel)
            case .plugins:
                PluginsPanelView()
                    .environmentObject(pluginModel)
            case .quit:
                QuitPanelView()
            case .none:
                Text("Select an item from the sidebar.")
                    .foregroundColor(.secondary)
            }
        }
    }
}
