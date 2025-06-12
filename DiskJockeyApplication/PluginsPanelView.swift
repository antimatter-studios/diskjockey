import SwiftUI

struct PluginsPanelView: View {
    @EnvironmentObject var pluginModel: PluginModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available Plugins").font(.title2).bold().padding(.bottom, 8)
            if pluginModel.plugins.isEmpty {
                Text("No plugins found.").foregroundColor(.secondary)
            } else {
                List(pluginModel.plugins) { plugin in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plugin.name).font(.headline)
                        Text(plugin.description).font(.subheadline).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(PlainListStyle())
            }
            Spacer()
        }
        .padding()
    }
}
