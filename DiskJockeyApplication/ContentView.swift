import SwiftUI

struct ContentView: View {
    @EnvironmentObject var pluginModel: PluginModel

    var body: some View {
        NavigationSplitView {
            List(selection: $pluginModel.selectedSidebarItem) {
                // About at the top
                Text("About").tag(SidebarItem.about)
                // Plugins
                ForEach(pluginModel.plugins) { plugin in
                    Text(plugin.name).tag(SidebarItem.plugin(plugin))
                }
            }
            .navigationTitle("Disk Jockey")
        } detail: {
            switch pluginModel.selectedSidebarItem {
            case .about:
                AboutView()
            case .plugin(let plugin):
                VStack(alignment: .leading, spacing: 16) {
                    Text(plugin.name)
                        .font(.title)
                        .bold()
                    Text(plugin.description)
                        .font(.body)
                    Spacer()
                }
                .padding()
            case .none:
                Text("Select an item from the sidebar.")
                    .foregroundColor(.secondary)
            }
        }
    }
}
