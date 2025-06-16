import SwiftUI
import DiskJockeyLibrary

/// A view that displays a list of available remote disk types
struct PluginListView: View {
    // MARK: - Properties
    
    @StateObject private var viewModel: PluginViewModel
    @State private var selectedPluginId: String?
    
    // MARK: - Body
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedPluginId) {
                ForEach(viewModel.plugins, id: \.id) { plugin in
                    PluginRow(plugin: plugin)
                        .contentShape(Rectangle())
                        .tag(plugin.id)
                }
            }
            .searchable(text: .constant(""), prompt: "Search remote disk types...")
            .navigationTitle("Remote Disk Types")
            .overlay {
                if viewModel.isLoading && viewModel.plugins.isEmpty {
                    ProgressView("Loading...")
                } else if viewModel.plugins.isEmpty {
                    ContentUnavailableView(
                        "No Remote Disk Types",
                        systemImage: "externaldrive",
                        description: Text("No remote disk types are currently available")
                    )
                }
            }
        } detail: {
            if let selectedId = selectedPluginId, 
               let plugin = viewModel.plugins.first(where: { $0.id == selectedId }) {
                PluginDetailView(plugin: plugin)
            } else {
                ContentUnavailableView(
                    "Select a Disk Type",
                    systemImage: "externaldrive",
                    description: Text("Select a remote disk type to view its details")
                )
            }
        }
        .task {
            await viewModel.loadPlugins()
        }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 600)
        #endif
    }
}

// MARK: - PluginRow

/// A single row in the plugin list
struct PluginRow: View {
    let plugin: Plugin
    @State private var isHovering = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plugin.name)
                        .font(.headline)
                    
                    if !plugin.description.isEmpty {
                        Text(plugin.description)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                
                Spacer()
                
                Text("v\(plugin.version)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(isHovering ? Color(nsColor: .controlBackgroundColor) : .clear)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
    }
}
